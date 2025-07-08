+++
author = 'Andrei Mahalean'
date = '2025-07-09'
draft = false
tags = ['azure', 'bicep', 'infrastructure-as-code']
title = 'Bicep Pain Points'
+++

# Bicep Pain Points: Why Azure's IaC Tool Still Needs Work

While Azure Bicep has made significant strides as Microsoft's domain-specific language for deploying Azure resources, it still falls short in several critical areas compared to more mature Infrastructure as Code (IaC) tools like Terraform. Here are some of the pain points that I have found while trying to implement a solution recently.

## 1. Pre-commit Hooks: Too Raw for Production Use

The current state of Bicep pre-commit integration feels decidedly unpolished. Unlike Terraform's rich ecosystem of pre-commit hooks, Bicep developers are left cobbling together basic bash scripts.

### Current Reality

```yaml
repos:
  - repo: local
    hooks:
      - id: bicep-lint-build
        name: Bicep Lint and Build
        entry: bash -c 'for file in $(git diff --cached --name-only | grep "\.bicep$"); do az bicep build --stdout --file "$file" && az bicep lint --file "$file"; done'
        language: system
        files: \.bicep$
        pass_filenames: false
        description: "Run az bicep build and lint on all staged .bicep files"
```

### Problems with This Approach

The most glaring issue with this cobbled-together approach is the brittle error handling - when the bash loop encounters a build failure, it doesn't gracefully recover or provide meaningful context about what went wrong. The script processes every file independently, completely missing the dependency relationships that are crucial in Bicep templates where modules often depend on each other's outputs.

### What We Need

- Native pre-commit hook support from the Bicep team
- Proper dependency graph awareness
- Meaningful error reporting with line numbers and context
- Integration with popular code quality tools

## 2. What-If Deployments: Noise Over Signal

Bicep's what-if functionality, while conceptually valuable, generates so much noise that it often obscures genuine changes, particularly when working with modules.

### The Module Output Reference Problem

When your Bicep templates reference module outputs, what-if reports these as "changes" even when the underlying resources remain unchanged. This creates a false sense of instability and erodes confidence in the deployment process.

**Example scenario:**
```bicep
module storage 'modules/storage.bicep' = {
  name: 'storageModule'
  params: {
    storageAccountName: 'mystorageaccount'
  }
}

resource containerGroup 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = {
  name: 'myContainerGroup'
  properties: {
    containers: [{
      properties: {
        environmentVariables: [{
          name: 'STORAGE_CONNECTION_STRING'
          value: storage.outputs.connectionString  // This shows as "change" in what-if
        }]
      }
    }]
  }
}
```

### Community Recognition

This isn't just our experience - the Azure team acknowledges this limitation. Progress is being tracked in [Azure ARM Template What-If Issue #157](https://github.com/Azure/arm-template-whatif/issues/157), and the updates from July 2025 fix the core functionality, but the output is still _noisy_. There has been a mention of new features such as bicep snapshot, so the hope remains we will have a more robust validation process which gives me confidence the changes are safe.

### Impact on Team Confidence

- **Lengthy review processes**: Teams spend excessive time investigating false positives
- **Reduced trust in automation**: Developers become hesitant to rely on what-if output
- **Manual verification overhead**: Critical changes get lost in the noise

## 3. Deployment Stack Validation: What does it tell us?

Azure Deployment Stacks promise to bring better lifecycle management to Azure resources, but their validation capabilities are severely limited.

### The Validation Gap

Running `az stack group validate` provides minimal actionable feedback:

```bash
az stack group validate \
  -g "$RESOURCE_GROUP" \
  --name "example-stack-dev" \
  --template-file "$STACK_TEMPLATE" \
  --parameters "$STACK_PARAM_FILE" \
  --deny-settings-mode none \
  --action-on-unmanage detachAll
```

The output shows a basic success status but lacks meaningful validation insights:

```json
{
  "error": null,
  "id": "/subscriptions/12345678-1234-1234-1234-123456789abc/resourceGroups/rg-example-test/providers/Microsoft.Resources/deploymentStacks/example-stack-dev",
  "name": "example-stack-dev",
  "properties": {
    "resources": [
      {
        "id": "/subscriptions/12345678-1234-1234-1234-123456789abc/resourceGroups/rg-example-test/providers/Microsoft.Resources/deployments/storage",
        "resourceGroup": "rg-example-test"
      },
      {
        "id": "/subscriptions/12345678-1234-1234-1234-123456789abc/resourceGroups/rg-example-test/providers/Microsoft.Resources/deployments/acr",
        "resourceGroup": "rg-example-test"
      },
      {
        "id": "/subscriptions/12345678-1234-1234-1234-123456789abc/resourceGroups/rg-example-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/mi-example-app-dev",
        "resourceGroup": "rg-example-test"
      },
      {
        "id": "/subscriptions/12345678-1234-1234-1234-123456789abc/resourceGroups/rg-example-test/providers/Microsoft.OperationalInsights/workspaces/law-example-app-dev",
        "resourceGroup": "rg-example-test"
      }
    ]
  },
  "resourceGroup": "rg-example-test",
  "systemData": null,
  "type": "Microsoft.Resources/deploymentStacks"
}
```

While the command succeeds and lists the resources that would be managed by the stack, it provides no insight into the validation process itself. The output simply confirms the stack structure without indicating what validation checks were performed or their results.

### Comparison with Other Tools

Terraform's `terraform plan` command provides rich, detailed output that helps developers understand exactly what will change and why. I know exactly what will change when working with Terraform, and I head into it with confidence.

## 4. The Missing `ignore_changes` Functionality

Perhaps the most frustrating limitation is Bicep's lack of an `ignore_changes` equivalent to Terraform's lifecycle management.

### Real-World Example: Container Groups

Consider a container group where the container definitions are managed by an external process (like a CI/CD pipeline updating image tags):

```bicep
resource containerGroup 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = {
  name: 'myContainerGroup'
  location: location
  properties: {
    containers: [{
      name: 'myContainer'
      properties: {
        image: 'myregistry.azurecr.io/myapp:latest'  // This changes frequently
        resources: {
          requests: {
            cpu: 1
            memoryInGb: 2
          }
        }
        environmentVariables: [
          {
            name: 'APP_ENV'
            value: 'production'
          }
        ]
      }
    }]
    osType: 'Linux'
  }
}
```

### The Problem

Every time the container image is updated externally, Bicep deployments attempt to "correct" the image back
 to the template-defined version, causing:

- **Deployment conflicts**: Bicep fights with external automation
- **Downtime**: Unnecessary container restarts
- **Workflow complexity**: Teams resort to complex workarounds

### Terraform's Solution

```hcl
resource "azurerm_container_group" "example" {
  # ... other configuration

  lifecycle {
    ignore_changes = [
      container.0.image
    ]
  }
}
```

### Current Workarounds (All Suboptimal)

1. **Separate templates**: Split infrastructure and application concerns (increases complexity)
2. **Parameter injection**: Pass current values as parameters (requires external state management)
3. **Conditional logic**: Complex template conditions (reduces readability)

## 5. Scoping Requirements: The RBAC Assignment Limitation

One of Bicep's most restrictive architectural limitations is its requirement that all resources within a file must exist in the same scope. This creates significant challenges when implementing Role-Based Access Control (RBAC) assignments alongside the resources they govern.

### The Scoping Problem

In Bicep, you cannot create a resource and assign RBAC permissions to it within the same file if they operate at different scopes. This forces developers into awkward architectural decisions and complex workarounds.

**Example scenario:**
```bicep
// This CANNOT be done in a single Bicep file
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: 'mystorageaccount'
  location: 'uksouth'
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
}

// ERROR: Cannot assign RBAC at subscription scope in the same file
// as the storage account (resource group scope)
resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: subscription() // Different scope!
  name: guid(subscription().id, 'Storage Blob Data Contributor')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
    principalId: managedIdentity.properties.principalId
  }
}
```

### The Subscription Scope Workaround

Creating resources at the subscription level requires even more convoluted patterns. As demonstrated in the [Azure quickstart templates](https://github.com/Azure/azure-quickstart-templates/blob/b992d1ef362f0c11601fb3a1419dc366c2680158/managementgroup-deployments/create-subscription-resourcegroup/main.bicep), you need multiple levels of nesting:

```bicep
// Creating resources in the subscription requires an extra level of "nesting"
// to reference the subscriptionId as a module output and use it for a scope.
// The module outputs cannot be used for the scope property
// so needs to be passed down as a parameter one level.

module subscriptionResources 'modules/subscription-level.bicep' = {
  name: 'subscriptionDeployment'
  scope: subscription()
  params: {
    subscriptionId: subscription().subscriptionId
  }
}

module resourceGroupResources 'modules/rg-level.bicep' = {
  name: 'resourceGroupDeployment'
  params: {
    subscriptionId: subscriptionResources.outputs.subscriptionId // Cannot use directly in scope
  }
}
```

### Impact on Architecture

This limitation forces several problematic patterns:

- **Module proliferation**: Simple deployments require multiple modules just to handle scope differences
- **Parameter passing overhead**: SubscriptionId and other scope identifiers must be explicitly passed as parameters
- **Deployment complexity**: What should be a single deployment becomes a chain of dependent modules
- **Reduced readability**: The intent gets lost in the architectural workarounds

### Real-World Consequences

Teams end up with:
- Separate Bicep files for infrastructure and RBAC
- Complex parameter files to coordinate between scopes
- Increased deployment time due to module dependencies
- Higher maintenance burden for simple scenarios

## Conclusion

While these limitations are frustrating, Bicep continues to evolve. The Azure team has shown responsiveness to community feedback, and several improvements are in the pipeline.

### What the Community Needs

1. **Enhanced tooling ecosystem**: Better integration with development workflows
2. **Improved what-if accuracy**: Resolution of module output reference issues
3. **Richer validation feedback**: Detailed stack validation reporting
4. **Lifecycle management**: Native ignore_changes functionality

### Making the Best of Current Limitations

- **Establish clear conventions**: Document when and how to work around limitations
- **Invest in custom tooling**: Build team-specific solutions where needed
- **Stay engaged**: Participate in Azure feedback channels and community discussions
- **Plan for evolution**: Design templates with future Bicep improvements in mind

### Community Solutions Are Emerging

While we wait for official improvements, the community is stepping up. One promising example is [bicep-docs](https://github.com/oWretch/bicep-docs), which attempts to replicate the terraform-docs experience for Bicep templates. Projects like this show that the tooling ecosystem is evolving, even if slowly.

## Conclusion

Bicep represents Microsoft's commitment to improving the Azure Infrastructure as Code experience, but it's not yet ready to fully replace more mature alternatives like Terraform for complex scenarios. Teams should carefully evaluate these limitations against their specific requirements and consider hybrid approaches where appropriate.

The good news? These are solvable problems, and the Azure team's track record suggests continued improvement. The question is whether your project timeline can accommodate the current limitations while waiting for these enhancements.

---

*Have you encountered similar issues with Bicep? Share your experiences and workarounds with me in [this Linkedin post](https://www.linkedin.com/posts/amahalean_bicep-pain-points-activity-7348485610170404864-N-ud?utm_source=share&utm_medium=member_desktop&rcm=ACoAABQhIxEBA70B_mhEmnN_O7G9Sb2cNHY3n7A)*
