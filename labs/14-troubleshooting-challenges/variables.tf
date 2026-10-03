# Variables shared by every stage. Each stage file declares its own variables
# next to the resources they control.

variable "aws_region" {
  description = "Region to deploy the shop into."
  type        = string
  default     = "ap-southeast-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.aws_region))
    error_message = "aws_region must look like an AWS Region identifier, for example ap-southeast-1."
  }
}

variable "project_name" {
  description = "Prefix for resource names and the Project tag. Keep it the same in every lab: changing it renames, and therefore replaces, most of the project."
  type        = string
  default     = "shop"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,20}[a-z0-9]$", var.project_name))
    error_message = "project_name must be 3-22 lowercase characters, digits or hyphens."
  }
}

variable "instance_type" {
  description = "EC2 instance type for every host in the project. t4g.nano is about USD 0.0053/hour."
  type        = string
  default     = "t4g.nano"
}

variable "instance_architecture" {
  description = "CPU architecture of instance_type: arm64 for Graviton (t4g), x86_64 otherwise."
  type        = string
  default     = "arm64"

  validation {
    condition     = contains(["arm64", "x86_64"], var.instance_architecture)
    error_message = "instance_architecture must be arm64 or x86_64."
  }
}

variable "additional_tags" {
  description = "Extra tags merged into the default tags applied to every resource."
  type        = map(string)
  default     = {}
}
