# variables.tf

variable "docker_image" {
  description = "The full ECR path and name of the Docker image to deploy."
  type        = string
  # No default value is set because the pipeline must always provide this.
}

variable "image_tag" {
  description = "The tag of the Docker image to deploy (e.g., the build number)."
  type        = string
  # No default value is set because the pipeline must always provide this.
}

variable "environment" {
  description = "The deployment environment, used for naming and workspaces (e.g., 'staging' or 'production')."
  type        = string
  # No default value is set because the pipeline must always provide this.
}

variable "instance_count" {
  description = "The number of container instances (tasks) to run."
  type        = number
  # No default value is set because the pipeline explicitly sets this for each environment.
}

variable "aws_region" {
  description = "AWS region for provider/resources"
  type        = string
  default     = "us-west-2"
}