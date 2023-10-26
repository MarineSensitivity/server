# server

The server software is for setting up web services outside those of Github (e.g. serving website, docs and R package) using Docker (see the [docker-compose.yml](https://github.com/MarineSensitivities/server/blob/main/docker-compose.yml); with reverse proxying from subdomains to ports by [Caddy](https://caddyserver.com)):

- [**rstudio**](https://rstudio.marinesensitivities.org)\
  _integrated development environment (IDE) to code and debug directly on the server_
  <img width="600" src="https://github.com/MarineSensitivities/server/assets/2837257/cfd04553-15a7-4cd9-9206-32bec377750a">\
  [More info..](https://posit.co/products/open-source/rstudio-server/)

- **shiny**\
  _interactive applications_\
  e.g., [**shiny**.marinesensitivities.org/**map**](https://shiny.marinesensitivities.org/map)\
  <img width="600" alt="Screenshot 2023-10-26 at 12 35 53 PM" src="https://github.com/MarineSensitivities/server/assets/2837257/36052617-275d-4d32-a1b5-f2db3a17c13a">\
  [More info..](https://shiny.posit.co/)
  
- [**pgadmin**](https://pgadmin.marinesensitivities.org)\
  _PostGreSQL database administration interface_\
  <img width="600" alt="Screenshot 2023-10-26 at 12 42 46 PM" src="https://github.com/MarineSensitivities/server/assets/2837257/4439a844-65c9-4ea2-9685-8ba6d4b2cd29">\
  [More info..](https://www.pgadmin.org/)

- [**api**](https://api.marinesensitivities.org)\
  _custom API using R plumber_\
  <img width="600" alt="Screenshot 2023-10-26 at 1 02 05 PM" src="https://github.com/MarineSensitivities/server/assets/2837257/3ff49d8c-8569-4111-9e63-2998960ea192">\
  [More info..](https://www.rplumber.io/)

-served  for R Shiny apps, RStudio IDE, R Plumber API, PostGIS database, pg_tileserv


## Connect

```bash
# ssh
pem='/Users/bbest/My Drive/private/msens_key_pair.pem'
ssh -i $pem ubuntu@msens1.marinesensitivities.org

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
```

## Reference

- [Server Setup](https://github.com/MarineSensitivities/server/wiki/Server-Setup) on AWS as EC2 instance at allocated IP address `100.25.173.0`





