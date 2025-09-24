# 0DBLab1fulldeploy.ps1
# Deployment script for FastAPI + DuckDB app

Write-Host "Starting deployment..."

# Define project structure
$projectRoot = "FastAPI_DuckDB_App"
$appFile = "$projectRoot\app.py"
$sqlFile = "$projectRoot\sql_server.py"
$venvPath = "$projectRoot\venv"

# Create directories
Write-Host "Creating project structure..."
New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null

# Create virtual environment
Write-Host "Creating virtual environment..."
python -m venv $venvPath

# Activate virtual environment
$activateScript = "$venvPath\Scripts\Activate.ps1"
Write-Host "Activating virtual environment..."
& $activateScript

# Install dependencies
Write-Host "Installing dependencies..."
pip install fastapi uvicorn pandas numpy pydantic sqlalchemy duckdb

# Create app.py
Write-Host "Creating app.py..."
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

# Create sql_server.py
Write-Host "📝 Creating sql_server.py..."
@"
import duckdb
from sqlalchemy import create_engine

def get_engine():
    return create_engine('duckdb:///:memory:')
"@ | Set-Content -Path $sqlFile

Write-Host "Deployment complete. To run the app:"
Write-Host "`n    cd $projectRoot"
Write-Host "    .\venv\Scripts\Activate.ps1"
Write-Host "    uvicorn app:app --reload"