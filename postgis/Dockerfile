FROM postgis/postgis:latest
# all files in directory docker-entrypoint-initdb.d are automatically executed
#   in alphabetical order on container creation
COPY ./add-user-anon-to-db.sh /docker-entrypoint-initdb.d/add-user-anon-to-db.sh
