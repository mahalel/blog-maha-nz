+++
author = 'Andrei Mahalean'
date = '2024-08-02'
tags = ['wsl', 'lazygit', 'git']
title = 'Open URLs from WSL in your default browser'
+++

When you prefer a terminal based workflow, and you want a bit more than the standard git cli (or any aliases you may have setup to make life easier), [lazygit](https://github.com/jesseduffield/lazygit) is hands down my favorite tool to work with. Please read the [elevator pitch](https://github.com/jesseduffield/lazygit?tab=readme-ov-file#elevator-pitch), then give it a try.

However, there is one feature that did not seem to work for me in WSL, until today that is.

## The Problem

When using lazygit in WSL, the `create pull request` feature (shortcut `o` when on branch view) typically fails because WSL doesn't have direct access to graphical applications. The `xdg-open` command, which lazygit uses to open URLs, doesn't work out of the box in WSL.

## The Solution

We'll create a custom script that intercepts `xdg-open` calls and redirects them to the Windows host system. This allows us to open pull requests in the default Windows browser directly from lazygit.

## Implementation

### Step 1: Create the WSL-Open Script

First, we'll create a script that acts as a bridge between WSL and Windows:

```bash
sudo hx /usr/local/bin/wsl-open
```

Add the following content:

```bash
#!/bin/bash

url="$1"

# Don't convert slashes for http/https URLs
if [[ "$url" == http* ]]; then
    # For web URLs, use the original URL without modification
    # Just escape single quotes for PowerShell
    escaped_url=$(echo "$url" | sed "s/'/''/g")
    powershell.exe -c "Start-Process '$escaped_url'"
else
    # For file paths, convert to Windows format
    winpath=$(echo "$url" | sed 's/\//\\/g')
    escaped_url=$(echo "$winpath" | sed "s/'/''/g")
    powershell.exe -c "Start-Process '$escaped_url'"
fi
```

Remember to make the script executable:

```bash
sudo chmod +x /usr/local/bin/wsl-open
```

### Step 2: Configure XDG-MIME

XDG-MIME is part of the XDG (X Desktop Group) standards, which are a set of freedesktop.org specifications for Unix-like operating systems, particularly Linux desktop environments. It is a command line tool for querying information about file type handling and adding descriptions for new file types.

Let's set `wsl-open`, the script we created in the previous step, as the default handler for HTTP(S) URLs:

```bash
xdg-mime default wsl-open.desktop x-scheme-handler/http
xdg-mime default wsl-open.desktop x-scheme-handler/https
```

### Step 3: Create a Desktop Entry

Create a `.desktop` file for our `wsl-open` script:

```bash
sudo hx /usr/share/applications/wsl-open.desktop
```

Add the following content, notice that we are using a placeholder `%u` for our URL which will be passed to the script when the desktop file is executed:

```txt
[Desktop Entry]
Name=WSL Open
Exec=/usr/local/bin/wsl-open %u
Type=Application
Terminal=false
MimeType=x-scheme-handler/http;x-scheme-handler/https;
```

### Step 4: Update XDG Settings

Set `wsl-open` as the default web browser for `xdg-open`:

```bash
xdg-settings set default-web-browser wsl-open.desktop
```

### Step 5: Configure Environment Variables

Add the following to your `~/.bashrc`:

```bash
export BROWSER=/usr/local/bin/wsl-open
```

The line sets the default browser for the WSL environment to your custom wsl-open script. This ensures that when a program in WSL tries to open a URL, it uses your script, which in turn passes the URL to the Windows host system.

Run `source ~/.bashrc` to apply changes.

## Testing the Setup

To test, run:

```bash
xdg-open "https://github.com/"
```

This should open the URL in your default Windows browser.

## Integration with Lazygit

With this setup in place, lazygit's 'open pull request' feature should now work seamlessly. When you select the option to open a pull request, lazygit will use `xdg-open`, which in turn calls our `wsl-open` script, opening the pull request URL in your Windows browser.

## Conclusion

This solution bridges the gap between WSL and Windows, allowing for a small productivity gain when working with Git and pull requests. It's particularly useful for developers who prefer terminal-based Git clients but still need the ability to quickly review and manage pull requests in a browser.
