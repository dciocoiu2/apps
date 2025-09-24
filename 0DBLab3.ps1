# Define project structure
$projectRoot   = "app1"
$appFile       = "$projectRoot\app.py"
$sqlFile       = "$projectRoot\sql_server.py"
$reqFile       = "$projectRoot\requirements.txt"
$manualFile    = "$projectRoot\lab_manual.md"

# Create project directory
Write-Host "Creating project directory..."
New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null

# Write requirements.txt
Write-Host "Writing requirements.txt..."
@"
fastapi
uvicorn
pandas
numpy
pydantic
sqlalchemy
duckdb
"@ | Set-Content -Path $reqFile

# Write sql_server.py
Write-Host "Writing sql_server.py..."
@"
import os
from sqlalchemy import create_engine

def get_engine():
    base_dir = os.path.dirname(__file__)
    db_path = os.path.join(base_dir, 'mydb.duckdb')
    return create_engine(f'duckdb:///{db_path}')
"@ | Set-Content -Path $sqlFile

# Write app.py
Write-Host "Writing app.py..."
@"
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from sqlalchemy import Column, Integer, String, MetaData, Table, select, text
from sqlalchemy.orm import registry, Session
import pandas as pd
import numpy as np
from sql_server import get_engine
from duckdb.typing import DuckDBPyType

DuckDBPyType.__hash__ = lambda self: hash(str(self))

mapper_registry = registry()
metadata = MetaData()

user_table = Table(
    "users",
    metadata,
    Column("id", Integer, primary_key=True),
    Column("name", String),
    Column("email", String),
)

@mapper_registry.mapped
class User:
    __table__ = user_table

class UserCreate(BaseModel):
    name: str
    email: str

class UserRead(UserCreate):
    id: int

app = FastAPI()
engine = get_engine()

with engine.begin() as conn:
    conn.execute(text("CREATE SEQUENCE IF NOT EXISTS user_id_seq START 1"))
    conn.execute(text(\"\"\"
        CREATE TABLE IF NOT EXISTS users (
            id INTEGER PRIMARY KEY DEFAULT nextval('user_id_seq'),
            name TEXT,
            email TEXT
        )
    \"\"\"))

@app.post("/users/", response_model=UserRead)
def create_user(user: UserCreate):
    try:
        with Session(engine) as session:
            new_user = User(**user.dict())
            session.add(new_user)
            session.commit()
            session.refresh(new_user)
            return new_user
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/users/{user_id}", response_model=UserRead)
def read_user(user_id: int):
    with Session(engine) as session:
        stmt = select(User).where(User.id == user_id)
        result = session.execute(stmt).scalar_one_or_none()
        if result is None:
            raise HTTPException(status_code=404, detail="User not found")
        return result

@app.get("/stats/")
def user_stats():
    df = pd.DataFrame({
        "age": np.random.randint(18, 65, size=100),
        "score": np.random.rand(100)
    })
    return df.describe().to_dict()
"@ | Set-Content -Path $appFile

# Write lab_manual.md
Write-Host "Writing lab_manual.md..."
@"
# Lab Manual

---

## Setup Instructions

### Windows
\`\`\`powershell
cd fastapi_duckdb_app
python -m venv venv
.\venv\Scripts\Activate.ps1
pip install -r requirements.txt
\`\`\`

### Linux / macOS
\`\`\`bash
cd fastapi_duckdb_app
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
\`\`\`

---

## Run the API Lab
\`\`\`bash
uvicorn app:app --reload
\`\`\`
Access the lab at: http://127.0.0.1:8000

---

## Test Endpoints

### Windows (PowerShell)

#### Create a User
\`\`\`powershell
Invoke-RestMethod -Uri "http://127.0.0.1:8000/users/" `
  -Method POST `
  -Body '{"name":"Alice","email":"alice@example.com"}' `
  -ContentType "application/json"
\`\`\`

#### Get a User
\`\`\`powershell
Invoke-RestMethod -Uri "http://127.0.0.1:8000/users/1" -Method GET
\`\`\`

#### Get Synthetic Stats
\`\`\`powershell
Invoke-RestMethod -Uri "http://127.0.0.1:8000/stats/" -Method GET
\`\`\`

---

### Linux / macOS (curl)

#### Create a User
\`\`\`bash
curl -X POST http://127.0.0.1:8000/users/ \
-H "Content-Type: application/json" \
-d '{"name":"Alice","email":"alice@example.com"}'
\`\`\`

#### Get a User
\`\`\`bash
curl http://127.0.0.1:8000/users/1
\`\`\`

#### Get Synthetic Stats
\`\`\`bash
curl http://127.0.0.1:8000/stats/
\`\`\`

---

### GUI Option: Postman or Insomnia
- Import OpenAPI spec from: http://127.0.0.1:8000/openapi.json
- Use visual interface to test endpoints
- Ideal for onboarding non-terminal users

---

## Extend the Lab
- Swap DuckDB for SQLite/PostgreSQL for integration testing
- Add role-based access or escalation paths
- Use FastAPI's OpenAPI docs at: http://127.0.0.1:8000/docs

---

## Safety Notes
- DuckDB runs in-memory; no persistent writes
- No external services or hardware dependencies
- Ideal for onboarding, regression testing, and plugin validation
"@ | Set-Content -Path $manualFile

# Final instructions
Write-Host "Lab scaffolded in '$projectRoot'."
Write-Host "Onboarding manual: lab_manual.md"
Write-Host "To get started:"
Write-Host "cd $projectRoot"
Write-Host "python -m venv venv"
Write-Host ".\\venv\\Scripts\\Activate.ps1   # Windows"
Write-Host "source venv/bin/activate         # Linux/macOS"
Write-Host "pip install -r requirements.txt"
Write-Host "uvicorn app:app --reload"