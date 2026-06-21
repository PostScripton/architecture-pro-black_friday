# MongoDB Sharding

Схема: 1 config server + 2 шарда + mongos router + API приложение.

## Запуск

```bash
docker compose up -d
```

## Инициализация шардирования

### 1. Инициализация config server replica set

```bash
docker compose exec -T configsvr mongosh --port 27017 --quiet <<EOF
rs.initiate({
  _id: "config_rs",
  configsvr: true,
  members: [{ _id: 0, host: "configsvr:27017" }]
})
EOF
```

### 2. Инициализация replica set шарда 1

```bash
docker compose exec -T shard1 mongosh --port 27018 --quiet <<EOF
rs.initiate({
  _id: "shard1_rs",
  members: [{ _id: 0, host: "shard1:27018" }]
})
EOF
```

### 3. Инициализация replica set шарда 2

```bash
docker compose exec -T shard2 mongosh --port 27019 --quiet <<EOF
rs.initiate({
  _id: "shard2_rs",
  members: [{ _id: 0, host: "shard2:27019" }]
})
EOF
```

### 4. Добавление шардов в кластер через mongos

```bash
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<EOF
sh.addShard("shard1_rs/shard1:27018")
sh.addShard("shard2_rs/shard2:27019")
EOF
```

### 5. Включение шардирования для базы данных и коллекции

```bash
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<EOF
sh.enableSharding("somedb")
sh.shardCollection("somedb.helloDoc", { "_id": "hashed" })
EOF
```

### 6. Наполнение базы данных тестовыми данными

```bash
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<EOF
use somedb
var bulk = db.helloDoc.initializeUnorderedBulkOp()
for (var i = 0; i < 1000; i++) {
  bulk.insert({ name: "user_" + i, age: Math.floor(Math.random() * 60) + 18 })
}
bulk.execute()
EOF
```

## Проверка

### Общее количество документов

```bash
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<EOF
use somedb
db.helloDoc.countDocuments()
EOF
```

### Количество документов в каждом шарде

Шард 1:

```bash
docker compose exec -T shard1 mongosh --port 27018 --quiet <<EOF
use somedb
db.helloDoc.countDocuments()
EOF
```

Шард 2:

```bash
docker compose exec -T shard2 mongosh --port 27019 --quiet <<EOF
use somedb
db.helloDoc.countDocuments()
EOF
```

### Статистика распределения по шардам

```bash
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<EOF
use somedb
db.helloDoc.getShardDistribution()
EOF
```

### API приложение

После инициализации откройте в браузере: http://localhost:8080

Эндпоинты:
- `GET /` - информация о топологии MongoDB и список коллекций с количеством документов
- `GET /helloDoc/count` - количество документов в коллекции helloDoc
