# MongoDB Sharding + Replication + Redis Cache

Схема: 1 config server + 2 шарда, каждый шард - реплика сет из 3 узлов + mongos router + Redis + API приложение.

Отличие от `mongo-sharding-repl`: добавлен сервис Redis. Приложение кеширует ответ эндпоинта `/<collection_name>/users` в Redis, поэтому повторные запросы выполняются заметно быстрее. Кеширование включается переменной окружения `REDIS_URL` (указывает на сервис redis: `redis://redis:6379`).

## Запуск

```bash
docker compose up -d
```

## Быстрая настройка (скрипт)

Все шаги ниже автоматизированы в `init.sh`:

```bash
chmod +x init.sh
./init.sh
```

После выполнения скрипта приложение доступно на http://localhost:8080.

## Настройка вручную

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

### 2. Настройка репликации шарда 1

Инициализируем реплика сет `shard1_rs` из трёх узлов. Команда выполняется на одном узле, который укажет остальных членов реплика сета.

```bash
docker compose exec -T shard1_node1 mongosh --port 27018 --quiet <<EOF
rs.initiate({
  _id: "shard1_rs",
  members: [
    { _id: 0, host: "shard1_node1:27018" },
    { _id: 1, host: "shard1_node2:27018" },
    { _id: 2, host: "shard1_node3:27018" }
  ]
})
EOF
```

### 3. Настройка репликации шарда 2

Аналогично инициализируем реплика сет `shard2_rs` из трёх узлов.

```bash
docker compose exec -T shard2_node1 mongosh --port 27019 --quiet <<EOF
rs.initiate({
  _id: "shard2_rs",
  members: [
    { _id: 0, host: "shard2_node1:27019" },
    { _id: 1, host: "shard2_node2:27019" },
    { _id: 2, host: "shard2_node3:27019" }
  ]
})
EOF
```

> После инициализации реплика сетам нужно несколько секунд на выбор primary. Подождите ~20 секунд перед следующим шагом.

### 4. Добавление шардов в кластер через mongos

При добавлении шарда указываем имя реплика сета и все его узлы.

```bash
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<EOF
sh.addShard("shard1_rs/shard1_node1:27018,shard1_node2:27018,shard1_node3:27018")
sh.addShard("shard2_rs/shard2_node1:27019,shard2_node2:27019,shard2_node3:27019")
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

### Статус репликации шарда

Проверяем, что реплика сет собран и узлы получили роли PRIMARY/SECONDARY:

```bash
docker compose exec -T shard1_node1 mongosh --port 27018 --quiet <<EOF
rs.status().members.map(m => ({ name: m.name, state: m.stateStr }))
EOF
```

### Общее количество документов

```bash
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<EOF
use somedb
db.helloDoc.countDocuments()
EOF
```

### Количество документов в каждом шарде

Запросы выполняются к primary узлу каждого шарда.

Шард 1:

```bash
docker compose exec -T shard1_node1 mongosh --port 27018 --quiet <<EOF
use somedb
db.helloDoc.countDocuments()
EOF
```

Шард 2:

```bash
docker compose exec -T shard2_node1 mongosh --port 27019 --quiet <<EOF
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
- `GET /` - топология MongoDB, список шардов, реплика сеты, количество документов в коллекциях и статус кеша (`cache_enabled`)
- `GET /helloDoc/count` - количество документов в коллекции helloDoc
- `GET /helloDoc/users` - список пользователей (ответ кешируется в Redis)

### Проверка кеширования

Первый запрос идёт в MongoDB и занимает > 1 секунды (в обработчике есть искусственная задержка `time.sleep(1)`). Второй и последующие запросы отдаются из Redis и выполняются `< 100мс`.

```bash
# Первый запрос - заполнение кеша (медленно)
curl -s -o /dev/null -w "%{time_total}s\n" http://localhost:8080/helloDoc/users

# Второй запрос - ответ из кеша (быстро, < 100мс)
curl -s -o /dev/null -w "%{time_total}s\n" http://localhost:8080/helloDoc/users
```

Что кеш активен, также видно в ответе `GET /` - поле `"cache_enabled": true`.
