# Deploying secure MLFlow on AWS

One of the many features of an MLOps platform is a capability of tracking and recording experiments which then can be shared and compared. It also involves storing and managing machine learning models and other artefacts.

[MLFlow](https://www.mlflow.org/) is a popular, open source project that tackles the above-mentioned functions. However, the standard MLFlow installation lacks any authorization mechanism. It is often a no-go letting anyone access your MLFlow dashboard. This repository deploys an oauth2-protected MLFlow in your AWS infrastructure.

## Solution overview

You can set up MLFlow in many ways, including a simple localhost installation. But to allow managing experiments and models collaboratively most of the production deployments will most likely end up being a distributed architecture with a remote MLFlow server and remote backend and artefact stores.

The following diagram depicts a high-level architecture of such a distributed approach.

![MLFlow deployment architecture](https://lh3.googleusercontent.com/fife/AAWUweUICrjeo-3dW3iP76wA8z6rQS638tHws6Vx4L4tO-fUQhOJc2Fb6UrEanMVBiWdL0LfRxToP2dW4GoaZqgVdBDsUEPixN5kWK252KOdEFIube3UYWkJQYBLX5AP_okY23xfiphHOGhGeq6RSLUr0-Ag5T26ZjRRT8L7_jm0zqqm_F6ikOt9WRL0q-PIIdi9xJLkgWFPz8j8NRXqcXY4XdOlfrJ9UX7xmGXXbTxyqAQDAPgXzrWKaiVXFaf7oeAPMTQjhOFovHr0GKCpAa4n-cUz4NHKMDdqCwdzwSYxd8JbfUM7pkF4-TzpytU0NjfvqG0MIwm4MpGOldh2GEsa8noq1ly4vDZS1CDc7tx0JU6pzHkzpekvUsCVoc_EZBC6cFsNf2iypo1MP-hGdHWkukxvhpjfbEw1DAuWZb-JjUD55LG1_Pt1vMTc24Tejsn-G_QLGrnFBsr4tJK01D2EFiFAFXJk0eqhuw3bv9oj_s3LzW6VleuCYwcidLOcGTIObgIOye71afvQTcaIJXpD-n7QO58_AsOv2CbGaHEUQ35p1ETooyryNsUNwIXYsYO6aPzZzKeeLobjrevSTwpMVmvjd9CAboLH_yFEPAjSHlZkkjRVmRFA7Qzzolal_wWU0iqj7A_O-SfYIEy80NgekKPoGCOlxVZCfHaCGDXWvKmpYCEy5K5FBCWJ4Ce6AQwByfSKq4yR6puKMMYJSYMV6ESCp1YbC06NkbA=w640-h400-k)

The main MLFlow infrastructure components are:

* MLFlow Tracking Server exposes API for logging parameters, metrics, experiments metadata and UI for visualising the results.
* Amazon Aurora Serverless used as the backend store where MLFlow stores metadata about experiments and runs, i.e., metrics, tags and parameters.
* AWS S3 used as the artefact store where MLFlow stores artefacts, e.g. models, data files.
* [oauth2-proxy](https://oauth2-proxy.github.io/oauth2-proxy/) protects MLFlow endpoints using OAuth2 compatible providers, e.g. Google.

The other AWS components provide runtime/compute environment (Elastic Container Service, ECS), routing (Application Load Balancer, ALB, and Route 53 as a DNS service) and security (Secrets Manager and Virtual Private Cloud, VPC).

## Setting up OAuth 2.0 client

To secure our MLFlow server we need to integrate with an OAuth2 provider. `oauth2-proxy` supports major OAuth2 providers and you can configure whichever you like. (Keep in mind that not all supported providers allow getting an authorization token which is needed for a programmatic access). In this setup Google provider is used. Follow [Setting up OAuth 2.0](https://support.google.com/cloud/answer/6158849?hl=en) instructions to create an OAuth 2.0 client. In the process

* Note the generated `Client Id` and `Client Secret` which we will need later.
* Specify `https://<your_dns_name_here>/oauth2/callback` in the `Authorized redirect URIs` field.

## Elastic Container Service

We deploy MLFlow and oauth2-proxy services as containers using [Elastic Container Service](https://docs.aws.amazon.com/ecs/index.html), ECS ([AWS App Runner](https://aws.amazon.com/apprunner/) is a nice serverless alternative, but at the time of creating this repository AWS App Runner service was available only in limited locations). We have two containers defined in an ECS task. Given that multiple containers within an ECS task in `awsvpc` networking mode share the network namespace, they can communicate with each other using localhost (similar to containers in the same kubernetes pod).

A relevant Terraform container definition for the MLFlow service is shown below.

```json
{
  name      = "mlflow"
  image     = "gcr.io/getindata-images-public/mlflow:1.22.0"
  entryPoint = ["sh", "-c"]
  command = [
    <<EOT
      /bin/sh -c "mlflow server \
        --host=0.0.0.0 \
        --port=${local.mlflow_port} \
        --default-artifact-root=s3://${aws_s3_bucket.artifacts.bucket}${var.artifact_bucket_path} \
        --backend-store-uri=mysql+pymysql://${aws_rds_cluster.backend_store.master_username}:`echo -n $DB_PASSWORD`@${aws_rds_cluster.backend_store.endpoint}:${aws_rds_cluster.backend_store.port}/${aws_rds_cluster.backend_store.database_name} \
        --gunicorn-opts '${var.gunicorn_opts}'"
    EOT
  ]
  portMappings = [{ containerPort = local.mlflow_port }]
  secrets = [
    {
      name      = "DB_PASSWORD"
      valueFrom = data.aws_secretsmanager_secret.db_password.arn
    }
  ]
}
```

The container setup is simple - we just start the MLFlow server with some options. Sensitive data, i.e., database password is fetched from Secret Manager (a cheaper option, but less robust, would be to use Systems Manager Parameter Store). ECS task is also given a role to access S3 where MLFlow stores  artefacts.

```json
resource "aws_iam_role_policy" "s3" {
  name = "${var.unique_name}-s3"
  role = aws_iam_role.ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = ["arn:aws:s3:::${aws_s3_bucket.artifacts.bucket}"]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:*Object"]
        Resource = ["arn:aws:s3:::${aws_s3_bucket.artifacts.bucket}/*"]
      },
    ]
  })
}
```

However, passing the backend store uri is at the moment a little bit convoluted. AWS ECS doesn't allow interpolating secrets in CLI arguments at runtime hence we need a shell. Preferably, MLFlow server should introduce an option to specify this value via an environment variable (there is an issue for that https://github.com/mlflow/mlflow/issues/3122).

Similarly, `oauth2-proxy` container definition is as follows.

```json
{
  name      = "oauth2-proxy"
  image     = "bitnami/oauth2-proxy:7.2.1"
  command   = [
    "--http-address", "0.0.0.0:8080",
    "--upstream", "http://localhost:${local.mlflow_port}",
    "--email-domain", "*",
    "--provider", "google",
    "--skip-jwt-bearer-tokens", "true",
    "--extra-jwt-issuers", "https://accounts.google.com=32555940559.apps.googleusercontent.com"
  ]
  portMappings = [{ containerPort = local.oauth2_proxy_port }]
  secrets = [
    {
      name      = "OAUTH2_PROXY_CLIENT_ID"
      valueFrom = data.aws_secretsmanager_secret.oauth2_client_id.arn
    },
    {
      name      = "OAUTH2_PROXY_CLIENT_SECRET"
      valueFrom = data.aws_secretsmanager_secret.oauth2_client_secret.arn
    },
    {
      name      = "OAUTH2_PROXY_COOKIE_SECRET"
      valueFrom = data.aws_secretsmanager_secret.oauth2_cookie_secret.arn
    },
  ]
}
```

Note, that `--extra-jwt-issuers` configuration option is needed to support programmatic access.

The premise of our setup is to put `oauth2-proxy` in front of MLFlow server, thus adding authorization capabilities. For this reason we configure ECS service's load balancer to point to the `oauth2-proxy` container, which, as the name implies, acts as a proxy to the MLFlow server.

```json
resource "aws_ecs_service" "mlflow" {

  # other attributes

  load_balancer {
    target_group_arn = aws_lb_target_group.mlflow.arn
    container_name   = "oauth2-proxy"
    container_port   = local.oauth2_proxy_port
  }
}
```

## Deployment

A complete Terraform stack is available for an easy and automatic deployment of all the required AWS resources.

### Prerequisites

You need to have installed the following tools

* AWS CLI
* Terraform CLI (v1.0.0+)

The Terraform stack will create the following resources

* A VPC with the accompanying network setup, e.g. subnets,  where most of the AWS resources run
* An S3 bucket for storing MLFlow artefacts
* Necessary IAM roles and policies for accessing the S3 bucket, secrets in Secrets Manager and running ECS tasks
* An Aurora Serverless database for storing MLFlow metadata
* An ECS cluster with a service running MLFlow tracking server and oauth2-proxy containers
* An Application Load Balancer, ALB, to route traffic to the ECS service and for SSL termination
* An A record in Route 53 to route traffic to ALB

However, prior to running Terraform commands you need to perform a few steps manually.

### Manual Steps

* Create an S3 bucket for storing a Terraform state. This step is not strictly necessary if you choose to keep the state locally

```bash
export TF_STATE_BUCKET=<bucketname>
aws s3 mb s3://$TF_STATE_BUCKET
aws s3api put-bucket-versioning --bucket $TF_STATE_BUCKET --versioning-configuration Status=Enabled
aws s3api put-public-access-block \
    --bucket $TF_STATE_BUCKET \
    --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
```

Enabling versioning and blocking public access is optional.

* Create a DynamoDB table for state locking. This step is not strictly necessary if you don’t enable state locking and consistency checking

```bash
export TF_STATE_LOCK_TABLE=<tablename>
aws dynamodb create-table \
   --table-name $TF_STATE_LOCK_TABLE \
   --attribute-definitions AttributeName=LockID,AttributeType=S \
   --key-schema AttributeName=LockID,KeyType=HASH \
   --provisioned-throughput ReadCapacityUnits=1,WriteCapacityUnits=1
```

* Create secrets in Secrets Manager. It includes OAuth2 ids, access keys to the S3 bucket and database password

```bash
aws secretsmanager create-secret \
   --name mlflow/oauth2-cookie-secret \
   --description "OAuth2 cookie secret" \
   --secret-string "<cookie_secret_here>"
 
aws secretsmanager create-secret \
   --name mlflow/store-db-password \
   --description "Password to RDS database for MLFlow" \
   --secret-string "<db_password_here>"
 
aws secretsmanager create-secret \
   --name mlflow/oauth2-client-id \
   --description "OAuth2 client id" \
   --secret-string "<oauth2_client_id_here>"
 
aws secretsmanager create-secret \
   --name mlflow/oauth2-client-secret \
   --description "OAuth2 client secret" \
   --secret-string "<oauth2_client_secret_here>"
```

### Deploy MLFlow

Run the following command to create all the required resources.

```bash
terraform init \
  -backend-config="bucket=$TF_STATE_BUCKET" \
  -backend-config="dynamodb_table=$TF_STATE_LOCK_TABLE" 
export TF_VAR_hosted_zone=<hosted_zone_name>
export TF_VAR_dns_record_name=<mlflow_dns_record_name>
export TF_VAR_domain=<domain>
terraform plan
terraform apply
```

Setting up the AWS infrastructure may take a few minutes. Once it’s completed you can navigate to the MLFlow UI (the URL will be printed in the `mlflow_uri` output variable). Authorise using your Google account.

## Programmatic access

Many MLFlow use cases involve accessing the MLFlow Tracking Server API programmatically, e.g. logging parameters or metrics in your kedro pipelines. In such scenarios you need to pass a Bearer token in the HTTP `Authorization` header. Obtaining such a token varies between providers. For Google, for instance, you could get the token running the following command:

```bash
gcloud auth print-identity-token
```

An authorised curl command listing the experiments would look like this:

```bash
curl -H "Authorization: Bearer $(gcloud auth print-identity-token)" https://<redacted>/api/2.0/mlflow/experiments/list
{
   "experiments": [
       {
           "experiment_id": "0",
           "name": "Default",
           "artifact_location": "s3://<redacted>/0",
           "lifecycle_stage": "active"
       }
   ]
}
```

Passing the authorization token to other tools is SDK-specific. For instance, MLFLow Python SDK supports Bearer authentication via the `MLFLOW_TRACKING_TOKEN` environment variable.
