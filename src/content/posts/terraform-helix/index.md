
+++
author = 'Andrei Mahalean'
date = '2024-08-22'
tags = ['helix', 'terraform']
title = 'Configuring Helix for Terraform'
draft = true
+++



```toml
# TERRAFORM
[[language]]
name = "hcl"
language-servers = [ "terraform-ls" ]
language-id = "terraform"

[[language]]
name = "tfvars"
language-servers = [ "terraform-ls" ]
language-id = "terraform-vars"

[language-server.terraform-ls]
command = "terraform-ls"
args = ["serve"]
```
