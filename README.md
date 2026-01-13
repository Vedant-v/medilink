ALTER ROLE medilink_dba PASSWORD 'shsvienyrtet83748rycndjkscuydnc';
docker compose exec db psql -U authenticator  -d medilink_db


use authenticator role for production