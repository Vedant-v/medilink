import os

print("🚀 Starting Django (DB handled by Postgres/PostgREST)")
os.execvp("python", ["python", "manage.py", "runserver", "0.0.0.0:8000"])
