resource "random_string" "suffix" {
  length  = 8
  upper   = false
  special = false
}

resource "aws_s3_bucket" "artifacts" {
  bucket = "${var.unique_name}-artifacts-${random_string.suffix.result}"
  tags   = local.tags
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
