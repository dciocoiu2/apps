# ODBLab1_setup.ps1
# Creates FastAPI + DuckDB app structure with source code and requirements.txt

$projectRoot = "fastapi_duckdb_app"
$appFile = "$projectRoot\app.py"
$sqlFile = "$projectRoot\sql_server.py"
$reqFile = "$projectRoot\requirements.txt"

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
duckdb-engine
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

Write-Host "Project setup complete in '$projectRoot'."
Write-Host "To install dependencies, run:"
Write-Host "`n    cd $projectRoot"
Write-Host "    python -m venv venv"
Write-Host "    .\venv\Scripts\Activate.ps1"
Write-Host "    pip install -r requirements.txt"
Write-Host "Then start the app with:"
Write-Host "    uvicorn app:app --reload"