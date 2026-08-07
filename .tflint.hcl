// TFLint configuration shared by every module in this repository.
// Run with: tflint --recursive  (or `make lint`)
//
// The AWS ruleset plugin is deliberately NOT enabled by default: it requires a
// network download on every `tflint --init` and its deep-check rules need AWS
// credentials. Set TFLINT_ENABLE_AWS_PLUGIN=1 and run `make lint-aws` if you
// want it locally. The bundled `terraform` ruleset is what CI enforces.

config {
  // Child modules are linted directly by `--recursive`, so do not descend into
  // `module "..."` sources a second time.
  call_module_type = "local"
  force            = false
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

// ---------------------------------------------------------------------------
// Naming: everything in this repo uses snake_case Terraform identifiers.
// ---------------------------------------------------------------------------
rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}

// A teaching repository is worthless without descriptions.
rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

rule "terraform_typed_variables" {
  enabled = true
}

// Pinned provider versions are a hard requirement of this repo.
rule "terraform_required_providers" {
  enabled = true
}

rule "terraform_required_version" {
  enabled = true
}

rule "terraform_unused_declarations" {
  enabled = true
}

rule "terraform_deprecated_interpolation" {
  enabled = true
}

rule "terraform_deprecated_index" {
  enabled = true
}

rule "terraform_comment_syntax" {
  enabled = true
}

// `terraform fmt` already owns formatting; `make fmt-check` enforces it.
rule "terraform_module_pinned_source" {
  enabled = true
}

// Every root module keeps variables/outputs/locals in dedicated files, which
// this rule would otherwise flag as "unexpected". Keep it off.
rule "terraform_standard_module_structure" {
  enabled = false
}
