# server
server setup for R Shiny apps, RStudio IDE, R Plumber API, PostGIS database, pg_tileserv


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





