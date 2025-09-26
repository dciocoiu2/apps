$folders = @("app", "rabbitmq")
foreach ($folder in $folders) {
    if (-not (Test-Path $folder)) {
        New-Item -ItemType Directory -Path $folder | Out-Null
    }
}

$appCode = @'
from fastapi import FastAPI, Depends, HTTPException, status, Request
from fastapi.security import OAuth2PasswordBearer
from pydantic import BaseModel
from pymongo import MongoClient
import redis
import requests

app = FastAPI()
oauth2_scheme = OAuth2PasswordBearer(tokenUrl="token")

users_db = {
    "admin": {"username": "admin", "role": "admin", "token": "admintoken"},
    "user": {"username": "user", "role": "user", "token": "usertoken"}
}

class User(BaseModel):
    username: str
    role: str

class Message(BaseModel):
    routing_key: str
    payload: str

def get_current_user(token: str = Depends(oauth2_scheme)) -> User:
    for user in users_db.values():
        if user["token"] == token:
            return User(username=user["username"], role=user["role"])
    raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token")

def require_role(required_role: str):
    def role_checker(user: User = Depends(get_current_user)):
        if user.role != required_role:
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Insufficient role")
        return user
    return role_checker

@app.get("/")
def read_root():
    return {"message": "Lab API is running"}

@app.get("/cache", dependencies=[Depends(require_role("user"))])
def cache_test():
    r = redis.Redis(host="redis", port=6379)
    r.set("lab", "ready")
    return {"cache": r.get("lab").decode()}

@app.get("/mongo", dependencies=[Depends(require_role("admin"))])
def mongo_test():
    client = MongoClient("mongodb://mongo1:27017/?replicaSet=rs0")
    db = client.lab
    db.status.insert_one({"status": "ok"})
    return {"mongo": "inserted"}

@app.post("/publish", dependencies=[Depends(require_role("admin"))])
def publish_message(msg: Message):
    try:
        res = requests.post(
            "http://rabbitmq1:15672/api/exchanges/%2F/amq.default/publish",
            auth=("guest", "guest"),
            json={
                "routing_key": msg.routing_key,
                "payload": msg.payload,
                "payload_encoding": "string"
            }
        )
        return res.json()
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
'@
Set-Content -Path "app\main.py" -Value $appCode -Encoding UTF8

$rabbitConf = @'
loopback_users.guest = false
cluster_formation.peer_discovery_backend = classic
cluster_formation.classic_config.nodes.1 = rabbit@rabbitmq2
cluster_formation.classic_config.nodes.2 = rabbit@rabbitmq3
'@
Set-Content -Path "rabbitmq\rabbitmq.conf" -Value $rabbitConf -Encoding UTF8

$compose = @'

services:
  rabbitmq1:
    image: rabbitmq:3-management
    hostname: rabbitmq1
    container_name: rabbitmq1
    ports:
      - "15672:15672"
      - "5672:5672"
    environment:
      RABBITMQ_ERLANG_COOKIE: "secretcookie"
      RABBITMQ_NODENAME: rabbit@rabbitmq1
    volumes:
      - ./rabbitmq/rabbitmq.conf:/etc/rabbitmq/rabbitmq.conf
    networks:
      - labnet

  rabbitmq2:
    image: rabbitmq:3-management
    hostname: rabbitmq2
    container_name: rabbitmq2
    environment:
      RABBITMQ_ERLANG_COOKIE: "secretcookie"
      RABBITMQ_NODENAME: rabbit@rabbitmq2
    networks:
      - labnet

  rabbitmq3:
    image: rabbitmq:3-management
    hostname: rabbitmq3
    container_name: rabbitmq3
    environment:
      RABBITMQ_ERLANG_COOKIE: "secretcookie"
      RABBITMQ_NODENAME: rabbit@rabbitmq3
    networks:
      - labnet

  redis:
    image: redis:7-alpine
    container_name: redis
    ports:
      - "6379:6379"
    networks:
      - labnet

  mongo1:
    image: mongo:6
    container_name: mongo1
    hostname: mongo1
    ports:
      - "27017:27017"
    command: mongod --replSet rs0 --bind_ip_all
    networks:
      - labnet

  mongo2:
    image: mongo:6
    container_name: mongo2
    hostname: mongo2
    command: mongod --replSet rs0 --bind_ip_all
    networks:
      - labnet

  mongo3:
    image: mongo:6
    container_name: mongo3
    hostname: mongo3
    command: mongod --replSet rs0 --bind_ip_all
    networks:
      - labnet

  mongoinit:
    image: mongo:6
    container_name: mongoinit
    depends_on:
      - mongo1
      - mongo2
      - mongo3
    entrypoint: >
      bash -c "
      sleep 8;
      mongosh --host mongo1:27017 <<EOF
      rs.initiate({
        _id: 'rs0',
        members: [
          { _id: 0, host: 'mongo1:27017' },
          { _id: 1, host: 'mongo2:27017' },
          { _id: 2, host: 'mongo3:27017' }
        ]
      });
      EOF
      "
    networks:
      - labnet

  api:
    image: tiangolo/uvicorn-gunicorn-fastapi:python3.11
    container_name: api
    ports:
      - "8000:80"
    volumes:
      - ./app:/app
    networks:
      - labnet
    depends_on:
      - redis
      - rabbitmq1
      - mongo1

networks:
  labnet:
    driver: bridge
'@
Set-Content -Path "docker-compose.yml" -Value $compose -Encoding UTF8

Write-Host "Lab scaffold created"
Write-Host "Start lab with docker-compose up -d"
Write-Host "Windows PowerShell test commands:"
Write-Host 'Invoke-RestMethod -Uri "http://localhost:8000"'
Write-Host 'Invoke-RestMethod -Uri "http://localhost:8000/cache" -Headers @{ Authorization = "Bearer usertoken" }'
Write-Host 'Invoke-RestMethod -Uri "http://localhost:8000/mongo" -Headers @{ Authorization = "Bearer admintoken" }'
Write-Host 'Invoke-RestMethod -Uri "http://localhost:8000/publish" -Method POST -Headers @{ Authorization = "Bearer admintoken" } -Body @{ routing_key = "test-queue"; payload = "Hello from FastAPI" } | ConvertTo-Json -Depth 3'
Write-Host 'Invoke-RestMethod -Uri "http://localhost:15672/api/queues/%2F/test-queue" -Method PUT -Headers @{ Authorization = "Basic Z3Vlc3Q6Z3Vlc3Q=" } -ContentType "application/json" -Body "{}"'
Write-Host 'Invoke-RestMethod -Uri "http://localhost:15672/api/exchanges/%2F/amq.default/publish" -Method POST -Headers @{ Authorization = "Basic Z3Vlc3Q6Z3Vlc3Q=" } -ContentType "application/json" -Body ''{ "routing_key": "test-queue", "payload": "Hello from PowerShell", "payload_encoding": "string" }'''
Write-Host 'Invoke-RestMethod -Uri "http://localhost:15672/api/queues/%2F/test-queue/get" -Method POST -Headers @{ Authorization = "Basic Z3Vlc3Q6Z3Vlc3Q=" } -ContentType "application/json" -Body ''{ "count": 1, "ackmode": "ack_requeue_false", "encoding": "auto", "truncate": 500 }'''
Write-Host "Stop lab with docker-compose down -v"