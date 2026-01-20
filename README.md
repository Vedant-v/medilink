ALTER ROLE medilink_dba PASSWORD 'shsvienyrtet83748rycndjkscuydnc';
docker compose exec db psql -U authenticator  -d medilink_db


use authenticator role for production

curl -X POST http://localhost:8000/auth/register/   -H "Content-Type: application/json"   -d '{
>     "username": "vedant01",
>     "email": "vedant@example.com",
>     "password": "Strong@Pass123",
>     "first_name": "Vedant",
>     "last_name": "kulkarni",
>     "primary_role": "doctor"
>   }'
