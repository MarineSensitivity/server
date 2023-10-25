#!/bin/bash

psql --username "admin" --dbname "msens" <<-END
    CREATE USER anon WITH PASSWORD '${ANON_PASSWORD}';
    GRANT CONNECT ON DATABASE msens TO anon;
    GRANT USAGE ON SCHEMA public TO anon;
    GRANT SELECT ON ALL TABLES IN SCHEMA public TO anon;
END
