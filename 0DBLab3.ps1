# setup.ps1
$projectRoot = "fastapi_duckdb_app"
$appFile = "$projectRoot\app.py"
$sqlFile = "$projectRoot\sql_server.py"
$reqFile = "$projectRoot\requirements.txt"
$manualFile = "$projectRoot\lab_manual.md"

Write-Host "Creating project directory..."
New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null

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

Write-Host "Writing sql_server.py..."
@"
import duckdb
from sqlalchemy import create_engine

def get_engine():
    return create_engine('duckdb:///:memory:')
"@ | Set-Content -Path $sqlFile

Write-Host "Writing app.py..."
@"
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from sqlalchemy import Column, Integer, String, MetaData, Table, select
from sqlalchemy.orm import registry, Session
import pandas as pd
import numpy as np
from sql_server import get_engine

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
metadata.create_all(engine)

@app.post("/users/", response_model=UserRead)
def create_user(user: UserCreate):
    with Session(engine) as session:
        new_user = User(**user.dict())
        session.add(new_user)
        session.commit()
        session.refresh(new_user)
        return new_user

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

Write-Host "Writing lab_manual.md..."
@"
#FastAPI + DuckDB API Lab Manual

##Setup Instructions

\`\`\`bash
cd fastapi_duckdb_app
python -m venv venv
.\venv\Scripts\Activate.ps1   # Windows
# Or: source venv/bin/activate  # macOS/Linux

pip install -r requirements.txt
\`\`\`

##Run the API Lab

\`\`\`bash
uvicorn app:app --reload
\`\`\`

##Test Endpoints

### Create a User

\`\`\`bash
curl -X POST http://127.0.0.1:8000/users/ \
-H "Content-Type: application/json" \
-d '{\"name\":\"Alice\",\"email\":\"alice@example.com\"}'
\`\`\`

### Get a User

\`\`\`bash
curl http://127.0.0.1:8000/users/1
\`\`\`

### Get Synthetic Stats

\`\`\`bash
curl http://127.0.0.1:8000/stats/
\`\`\`

## Extend the Lab

- Swap DuckDB for SQLite/PostgreSQL for integration testing
- Add role-based access or escalation paths
- Use FastAPI’s OpenAPI docs at http://127.0.0.1:8000/docs

## Safety Notes

- DuckDB runs in-memory; no persistent writes
- No external services or hardware dependencies
- Ideal for onboarding, regression testing, and plugin validation
"@ | Set-Content -Path $manualFile

Write-Host "Lab scaffolded in '$projectRoot'."
Write-Host "Onboarding manual: lab_manual.md"
Write-Host "`nTo get started:"
Write-Host "    cd $projectRoot"
Write-Host "    python -m venv venv"
Write-Host "    .\\venv\\Scripts\\Activate.ps1"
Write-Host "    pip install -r requirements.txt"
Write-Host "    uvicorn app:app --reload"