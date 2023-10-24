# server
server setup for R Shiny apps, RStudio IDE, R Plumber API, PostGIS database, pg_tileserv

## ssh to server

Launched instance in AWS Console: Ubuntu free tier 1 CPU, 8 GB. 54.224.247.234.

For now `msens.micro` VM instance:

```bash
pem=/Users/bbest/My Drive/private/msens_key_pair.pem
ssh -i $pem ubuntu@ec2-54-224-247-234.compute-1.amazonaws.com
```

## install docker

Following:

* [Step-by-Step Guide to Install Docker on Ubuntu in AWS | by Srija Anaparthy | Medium](https://medium.com/@srijaanaparthy/step-by-step-guide-to-install-docker-on-ubuntu-in-aws-a39746e5a63d)

```bash
sudo apt-get update
sudo apt-get install docker.io -y
sudo systemctl start docker
sudo docker run hello-world
sudo systemctl enable docker
docker --version
sudo usermod -a -G docker $(whoami)
df -H
```

```
Filesystem      Size  Used Avail Use% Mounted on
/dev/root       8.2G  2.3G  5.9G  28% /
tmpfs           498M     0  498M   0% /dev/shm
tmpfs           200M  885k  199M   1% /run
tmpfs           5.3M     0  5.3M   0% /run/lock
/dev/xvda15     110M  6.4M  104M   6% /boot/efi
tmpfs           100M  4.1k  100M   1% /run/user/1000
```


```bash
sudo apt install docker-compose

git clone https://github.com/MarineSensitivities/server.git
cd server
docker-compose up -d
```
