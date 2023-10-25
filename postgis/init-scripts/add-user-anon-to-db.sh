#!/bin/bash
set -e

psql -v ON_ERROR_STOP=1 --username "admin" --dbname "$PASSWORD" <<-EOSQL
    CREATE USER anon WITH PASSWORD '$ANONPASSWORD';
    GRANT CONNECT ON DATABASE msens TO anon;
    GRANT USAGE ON SCHEMA public TO anon;
    GRANT SELECT ON ALL TABLES IN SCHEMA public TO anon;
EOSQL
