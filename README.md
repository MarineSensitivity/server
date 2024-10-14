# server

The server software is for setting up web services outside those of Github (e.g. serving website, docs and R package) using Docker (see the [docker-compose.yml](https://github.com/MarineSensitivity/server/blob/main/docker-compose.yml); with reverse proxying from subdomains to ports by [Caddy](https://caddyserver.com)):

## Quick Start

```bash
# setup folders
mkdir -p /share/github

# clone the repository
cd /share/github
git clone https://github.com/MarineSensitivity/server

# set environment variables: echo echo
cd /share/github/server
echo 'PASSWORD=*******' > .env

# docker launch as daemon
docker compose up -d
```


## Services

- [**rstudio**](https://rstudio.marinesensitivity.org)\
  _integrated development environment (IDE) to code and debug directly on the server_
  <img width="600" src="https://github.com/MarineSensitivity/server/assets/2837257/cfd04553-15a7-4cd9-9206-32bec377750a">\
  [More info..](https://posit.co/products/open-source/rstudio-server/)

- **shiny**\
  _interactive applications_\
  e.g., [**shiny**.marinesensitivity.org/**map**](https://shiny.marinesensitivity.org/map)\
  <img width="600" alt="Screenshot 2023-10-26 at 12 35 53 PM" src="https://github.com/MarineSensitivity/server/assets/2837257/36052617-275d-4d32-a1b5-f2db3a17c13a">\
  [More info..](https://shiny.posit.co/)
  
- [**pgadmin**](https://pgadmin.marinesensitivity.org)\
  _PostGreSQL database administration interface_\
  <img width="600" alt="Screenshot 2023-10-26 at 12 42 46 PM" src="https://github.com/MarineSensitivity/server/assets/2837257/4439a844-65c9-4ea2-9685-8ba6d4b2cd29">\
  [More info..](https://www.pgadmin.org/)

- [**api**](https://api.marinesensitivity.org)\
  _custom API: using R plumber_\
  <img width="600" alt="Screenshot 2023-10-26 at 1 02 05 PM" src="https://github.com/MarineSensitivity/server/assets/2837257/3ff49d8c-8569-4111-9e63-2998960ea192">\
  [More info..](https://www.rplumber.io/)
  
- [**swagger**](https://swagger.marinesensitivity.org)\
  _generic database API: using PostGREST_\
  <img width="600" alt="Screenshot 2023-10-26 at 1 02 05 PM" src="https://github.com/MarineSensitivity/server/assets/2837257/787cc7b6-b1cd-4c1a-b896-4f17777b1d7d">\
  [More info..](https://postgrest.org/en/stable/)

- [**tile**](https://tile.marinesensitivity.org)\
  _spatial database API: using pg_tileserv for serving vector tiles_\
  <img width="667" alt="Screenshot 2023-10-26 at 1 46 00 PM" src="https://github.com/MarineSensitivity/server/assets/2837257/73398fe2-4b09-4ec9-8b14-2ef25165ecf4">\
  [More info..](https://postgrest.org/en/stable/)


## Connect

```bash
# ssh
pem='/Users/bbest/My Drive/private/msens_key_pair.pem'
ssh -i $pem ubuntu@msens1.marinesensitivity.org

# ssh with tunneling to postgis database
pem='/Users/bbest/My Drive/private/msens_key_pair.pem'
ssh -i $pem -L 5432:localhost:5432 ubuntu@msens1.marinesensitivity.org

# $PASSWORD
cat '/Users/bbest/My Drive/private/msens_server_env-password.txt'
```

## Restart

```bash
cd ~/server
git pull

# restart with any new configs
sudo docker restart

# update software
sudo docker compose up -d

# check disk space and remove big unused files interactively
sudo ncdu

# remove unused docker images, containers, and networks
docker system prune

# build new plumber api container
docker compose up --build plumber
```

## Reference

- [Server Setup](https://github.com/MarineSensitivity/server/wiki/Server-Setup) on AWS as EC2 instance at allocated IP address `100.25.173.0`


## 2024-06-17

- [CRAN as Ubuntu Binaries - r2u](https://eddelbuettel.github.io/r2u/#github-actions)

```bash
sudo apt upgrade
```


