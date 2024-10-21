+++
author = 'Andrei Mahalean'
date = '2024-10-18'
tags = ['azure', 'github-actions']
title = 'Deploying multiple containers in Azure Container Apps with Github Actions'
+++

Recently, I have been working on a little web application which needed to be deployed in an Azure Container App (**ACA**).

My past experience is mainly using Azure DevOps, but this time I am using Github and I wanted to know what is the best way to build and deploy my container in ACA using Github Actions (**GHA**).
It seemed very easy and straight forward to do so, but I quickly ran into some limitations of the action when a new use case emerged and I needed to deploy a proxy-auth sidecar container in the same ACA as my webapp.

In this post, I'm sharing my experience of getting everything up and running. The cool part? I stuck with using the Action instead of falling back on `az cli` commands in the workflow. 

# Preface - OIDC auth to Azure

Before I get into the main post, I just wanted to touch on how great [Workload Identity Federation](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation#supported-scenarios) is for setting up authentication for deploying resources into Azure from GHA.
All you need to do, is setup either a User Assigned managed identity or an App Registration, give it the appropriate IAM permissions over the scope you want it to touch (a Resource Group for example, or a whole Subscription if you are an absolute mad person) then [configure the federated identity for Github Actions](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation-create-trust-user-assigned-managed-identity?pivots=identity-wif-mi-methods-azp#github-actions-deploying-azure-resources). 


The flow of getting a token is:

![GH OIDC Flow](./gh_oidc_flow.png)


In your Github Workflow you simply invoke the `azure/login` action and pass it a client-id, tenant-id and subscription-id: 

  ```yml
    - name: Azure login
      uses: azure/login@v2
      with:
        client-id: ${{ secrets.AZURE_CLIENT_ID }}
        tenant-id: ${{ secrets.AZURE_TENANT_ID }}
        subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
  ``` 

Also, at the job level, set the following permissions for the token:

  ```yml
    permissions:
      id-token: write
      contents: read
  ``` 

**That's it!**, you don't have to deal with any secrets, you don't have to ever worry about secrets expiring and needing to be rotated, easy as!

With that out of the way, we can move onto building our app and deploying it to ACA.

# Github Action to build and deploy container image to ACA

A quick search led me to the official [Container Apps Deploy action](https://github.com/Azure/container-apps-deploy-action), this can both build and deploy containers. It can even create a new resource group and ACA for you if needed, but in my case, I had already deployed all this plus a Container Registry, via Terraform, so I only need the build and deploy functionality.

Well, that is unless you want to apply multiple tags to the image, such as the commit `sha` and `latest`, in which case you need to break out the build into a separate step and do it via the `az acr build` command which allows you to apply several tags on build. For my case, I only need one tag (the commit sha) on the image so that was not an issue, **however** I still ended up breaking the image build into its own job, I will explain later why that is.

At this point we got something along these lines in place

  ```yml
    - name: Build and deploy Container App
      uses: azure/container-apps-deploy-action@v1
      with:
        containerAppName: ${{ secrets.CAPP_NAME }}
        imageToBuild: ${{ secrets.REGISTRY_NAME }}.azurecr.io/${{ env.IMAGE_NAME }}:${{ github.sha }}
        resourceGroup: ${{ secrets.RG_NAME }}
        environmentVariables: ${{ vars.ENVIRONMENT_VARIABLES }}
  ```

Notice that I am passing a list of environment variables to the action, these are single line, space separated, key value pairs, stored in a GitHub environment variables list.
So far, this works really great but don't fall into the trap of thinking we got off so easy.

# Authn + Authz required

It is at this point that I realised I wanted to also add authentication via GitHub Oauth to the application.
The easiest way to do this is via [ACA Easy Auth](https://learn.microsoft.com/en-us/azure/container-apps/authentication) which I would recommend using when possible, as it is extremely easy to setup.

In my case, I wanted to configure auth via Github, which is trivial to do via Easy Auth in ACA, but the limitation I could not find a way around was only allowing users from a specific GitHub Organisation to access the application. From my testing, Easy Auth seems to allow anyone with a GitHub login to access the App once they have given my OAuth App permissions.
It is possible I missed something here, so if anyone has a clue how to restrict this access properly, please [mesasge me on Linkedin](https://www.linkedin.com/in/amahalean/) and tell me I'm an idiot.

With this in mind, I decided to deploy my own proxy-auth sidecar container alongside my main app and use this for greater control of the Authn & Authz flow.

# Finding the limitations of the action

Things are now getting a bit more complicated. We now need to deploy:
- One ACA
- with 2 containers
- each with a dynamic image name (`image:sha`)
- each with a separate set of environment variables

Also we need to build and deploy both images to ACR outside of the GHA as it cannot do this for more than one image at a time.

Let's do that first, with a build job:

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read
    strategy:
      matrix:
        app: ["app", "proxy"]

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Azure login
        uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

      - name: "Build and push image"
        run: |
          az acr build --image ${{ matrix.app }}-image:${{ github.sha }} --registry ${{ secrets.REGISTRY_NAME }} --file ${{ matrix.app }}/Dockerfile ${{ matrix.app }}
```

Here we are making use of a matrix build strategy so we can build both images at the same time, there are no dependencies between them:

![Matrix Build](./matrix_build.png)

Great, we have both images built and pushed into our ACR but how can we deploy them both into our ACA?

According to the `container-apps-deploy-action` documentation, we should be able to deploy multiple containers in the same ACA, but instead of passing the details of the image and the environment variables as input parameters for the app, we need to pass a [YAML configuration file](https://github.com/Azure/container-apps-deploy-action?tab=readme-ov-file#arguments-required-for-using-a-yaml-configuration-file) with the `yamlConfigPath` input parameter.

Let's craft the YAML file based on the [example schema](https://learn.microsoft.com/en-nz/azure/container-apps/azure-resource-manager-api-spec?tabs=yaml#container-app-examples) that they provide:

```yaml
properties:
  template:
    containers:
      - image: __APPLICATION__
        name: container-app
        resources:
          cpu: 0.25
          memory: 0.5Gi     
      - image: __PROXY__
        name: container-proxy
        resources:
          cpu: 0.25
          memory: 0.5Gi     
```

That takes care of the first 3 requirements. As you may have noticed, I am using some `__PLACEHOLDERS__` for both the app and proxy image names.
These are updated in the workflow via a `run` command using `sed` as such:

```yaml
      - name: Update containers template
        run: |
          sed -i 's|__APPLICATION__|${{ secrets.REGISTRY_NAME }}.azurecr.io/app-image:${{ github.sha }}|g' ${{ github.workspace }}/aca-containers.yml
          sed -i 's|__PROXY__|${{ secrets.REGISTRY_NAME }}.azurecr.io/proxy-image:${{ github.sha }}|g' ${{ github.workspace }}/aca-containers.yml
```

Great, but how do we define environment variables for each container?

Looking at the example schema linked above, I couldn't see anything mentioning environment variables, but I know in the terrafrom container app template definition we can pass a list to each container, so we should be able to do it here, right?

Not only that, there are two types of environment variables in ACA container templates. The first are simple variables passed with `name,value` keys in plaintext. The second are [secret references](https://learn.microsoft.com/en-us/azure/container-apps/manage-secrets?tabs=azure-cli#using-secrets) passed as `name,secretref` keys, the value of a `secretref` can be a previously created secret in ACA, or a secret linked to a KeyVault.

Digging deeper into the Azure management [REST API schema](https://learn.microsoft.com/en-nz/rest/api/containerapps/container-apps/create-or-update?view=rest-containerapps-2024-03-01&tabs=HTTP#container) I can see that alongside `name`, `image`, `resources`, there is also the option of an `env` list, of type `EnvironmentVar`, which can take our secrets.

I want to set these dynamically in our YAML template, so we don't have to update the code and make a PR every time we want to add a new variable to a container.

# It works!

With this in mind, I chose the following strategy.

1. Define a list of variables for each container as a JSON object in GitHub environment variables. These don't need to be secrets as we are at most referencing a secret via `secretref` and not storing anything in plaintext:
2. Create a bash function that takes in an argument (JSON object from our variable), and uses `jq` to format the environment variables into an array of key-value pairs. 

```sh
# Function to format env vars
format_env_vars() {
  echo "$1" | jq -r 'to_entries[] | if .value | startswith("secretref:") then
    "          - name: " + .key + "\n            secretRef: " + (.value | sub("secretref:"; ""))
  else
    "          - name: " + .key + "\n            value: " + .value
  end'
}
```


The `if` statement checks each value:
- If the value starts with "secretref:", it's treated as a reference to a secret.
- Otherwise, it's treated as a regular environment variable.

For example, if you pass this JSON:

```json
{
  "DATABASE_URL": "mysql://user:pass@host:3306/db",
  "API_KEY": "secretref:api-key-secret"
}
```

The function would output:

```yaml
- name: DATABASE_URL
  value: mysql://user:pass@host:3306/db
- name: API_KEY
  secretRef: api-key-secret
```

3. Insert the formatted output under the `env` section for each of our containers in the `aca-containers.yml` template:


```yaml
  # Insert APP_ENV_VARS
  app_vars=$(format_env_vars "$APP_ENV_VARS")
  awk -v vars="$app_vars" '
    /name: container-app/,/env:/ {
      if ($0 ~ /env:/) {
        print $0
        print vars
        next
      }
    }
    {print}
  ' ${{ github.workspace }}/aca-containers.yml > temp.yml && mv temp.yml ${{ github.workspace }}/aca-containers.yml

  # Insert PROXY_ENV_VARS
  proxy_vars=$(format_env_vars "$PROXY_ENV_VARS")
  awk -v vars="$proxy_vars" '
    /name: container-proxy/,/env:/ {
      if ($0 ~ /env:/) {
        print $0
        print vars
        next
      }
    }
    {print}
  ' ${{ github.workspace }}/aca-containers.yml > temp.yml && mv temp.yml ${{ github.workspace }}/aca-containers.yml
```

As we wrap up, it's clear that deploying multiple containers to Azure Container Apps using GitHub Actions can be a bit of a journey. 

While the official Container Apps Deploy action is a great starting point, it may not cover all scenarios out of the box - especially when you're dealing with multiple containers and complex environment variable setups.
However, with a bit of creativity and some bash scripting magic, we can extend the functionality to meet our needs. By leveraging GitHub's matrix build strategy, crafting a custom YAML configuration file, and using some nifty jq commands, we've managed to create a flexible and powerful deployment pipeline.

As always in the world of DevOps, there's probably more than one way to skin this cat. If you've found an alternative approach or have any suggestions for improvements, I'd love to hear about them. Drop me a line on LinkedIn and let's chat!
