#!/bin/sh
HOST=blog
DIR=/var/www/html/   # the directory where your website files should go

hugo --source=./src && rsync -avz --delete src/public/ ${HOST}:${DIR} # this will delete everything on the server that's not in the local public folder 

exit 0

