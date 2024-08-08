+++
author = "Andrei Mahalean"
title = "Blog Setup"
date = "2024-08-06"
tags = [
    "hugo",
    "terraform",
]
draft = true
+++

In this post, I explore the technology stack powering this blog, detailing the tools and processes used for both authoring content and deploying the site. 

Requirements which I have considered that led me to my final choices:

- **Simple**: I have a full time job and a family. The last thing I want to do is spend time troubleshooting a k8s cluster if my blog is down. I want to take out complexity out of the equation and make sure I have the least amount of tech friction, so I can focus on the content.
- **Cheap**: Predictable cost, no surprises needed. Static monthly fee is ideal.
- **Reproductible**: A side-effect of simplicity, if something is not working and I have spent more than 10 minutes troubleshooting it, blow the whole thing away and re-deploy it easily.
- **Fast**: Minimalistic theme, fast build time, quick deployments. Keep it light (but in dark mode of course).
- **Secure**: Use HTTPS, ensure HSTS and other security headers can be easily set.
- **Control**: I want to be in control of the platform. I know I could just do this in Github Pages, or some S3/Azure Storage static hosting, but I need to have control over the webserver configuration.

## Decision
With this in mind, I have decided to host the blog on the smallest DigitalOcean droplet, which comes with 512MB of memory and a 10GB disk, in the Sydney region.

The system is running Debian 12 and uses Caddy as a webserver. This is great because Caddy will automatically sort out the TLS certificate using LetsEncrypt so that is one less thing to worry about.
cloud-init is used to install caddy and apply the Caddyfile configuration for the site.

I use HCP Terraform free tier to deploy all DigitalOcean infrastructure, including my DNS records.

## Infrastructure

![](https://app.eraser.io/workspace/EvRoTb1NQkUziDYIR8CZ/preview?elements=dNmjvjltfDCEtonUU3Oh2A&type=embed)

<!-- (https://app.eraser.io/workspace/EvRoTb1NQkUziDYIR8CZ?elements=dNmjvjltfDCEtonUU3Oh2A) -->

For deploying I use a VCS workflow, where a push to my private infra GitHub repo will trigger a Terraform plan & apply.


## Authoring

The blog is hosted as a [github public repository](https://github.com/mahalel/blog-maha-nz). The source directory for Hugo is the `./src` folder. To add a new post I add it as Markdown to the `./src/content` folder. The theme is the [Hugo Bear Cub theme](https://github.com/clente/hugo-bearcub) which is added as a Git submodule.

Dependencies are installed via the nix flake available at the root of the repository, this can be loaded either manually with `nix develop` or with a [direnv](https://github.com/direnv/direnv) configuration that applies the flake when you enter the root folder.

I edit the `md` files with my primary editor [helix](https://helix-editor.com/) or with Visual Studio Code as my backup editor if that is ever needed.

**TODO** - Images are added to the static/content folder as webp format. Do we auto-convert it somehow?
 
### Deployment

**Local**

My SSH config is configured with the user, host & identity file for the blog. With this in place I can simply run the [deploy.sh](https://github.com/mahalel/blog-maha-nz/blob/main/deploy.sh) script locally and it will build the site then rsync it over.

This is simple and fast enough for my needs, I may wrap this up in a Makefile or [Taskfile](https://taskfile.dev/) later on.

**Github Workflow**

A Github action has been setup which will deploy the site contents. This can be trigerred on push, manually, and it will also run on a schedule every 5 minutes. The 5 minutes is a best effort though, as Github can [delay your schedule](https://docs.github.com/en/actions/writing-workflows/choosing-when-your-workflow-runs/events-that-trigger-workflows#schedule) during periods of high loads. 

The action will first check the status code returned by a `curl` request to the root of the blog. When the response status code is 404 it means that I have redeployed the infra and the droplet has been rebuilt. Because the webserver responds to http traffic, but there is no content at the root, it is implied that the site is ready to have its content re-deployed. 

The deployment is a recreation of the rsync deploy script, as GitHub actions. Hugo is pinned to a specific version which _should_ match the version retrieved via the nix flake.

The ECDSA key that allows the rsync command to succeed is read as a GitHub secret, we need to disable StrictHostKey checking and ignore known hosts signature because each droplet rebuild will give us a different host key. 


I will consider adding a GitHub self-hosted runner in the future if I want to reduce the time the site is unavailable between rebuilds, but at this point I am ok with this downside.

## Analytics

None. I was toying with the idea of using Matomo but I then realised focusing on the numbers would be the wrong incentive for writing. I decided to proceed without any analytics.

## Monitoring

For now, I am using a Digitalocean HTTP Uptime Check which will email me when there is no response to a HTTPS request. After I rebuild my home server I will switch it over to use [Uptime Kuma](https://github.com/louislam/uptime-kuma)

## Optimizations

HTTP Observatory is a free online tool that scans websites for security vulnerabilities and best practices, I have used it to help me improve the web security of the site by providing detailed reports and recommendations on various security headers, SSL/TLS configuration, and other critical security measures.

Based on the recommendations, I have managed to [achieve an A+ score](https://developer.mozilla.org/en-US/observatory/analyze?host=blog.maha.nz) with the following Caddyfile configuration:

```txt
blog.maha.nz {
  root * ${PUBLIC}
  file_server

  # Add multiple headers
  header {
      X-Frame-Options "deny"
      X-XSS-Protection "1; mode=block"
      Content-Security-Policy: "default-src 'none'; manifest-src 'self'; font-src 'self'; img-src 'self'; style-src 'self'; form-action 'none'; frame-ancestors 'none'; base-uri 'none'"
      X-Content-Type-Options: "nosniff"
      Strict-Transport-Security: "max-age=31536000; includeSubDomains; preload"
      Cache-Control: max-age=31536000, public
      Referrer-Policy: no-referrer
      Feature-Policy: microphone 'none'; payment 'none'; geolocation 'none'; midi 'none'; sync-xhr 'none'; camera 'none'; magnetometer 'none'; gyroscope 'none'
  }
} 
```

## Future improvements

- Update monitoring to Uptime Kuma
- Wrap up the deploy in a taskfile
- Add self-hosted runner for shorter downtime
