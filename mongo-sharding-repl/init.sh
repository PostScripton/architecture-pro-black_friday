#!/usr/bin/env bash
# Автоматическая настройка шардированного кластера MongoDB с репликацией.
# Перед запуском поднимите стенд: docker compose up -d

set -e

echo "1. Инициализация config server replica set"
docker compose exec -T configsvr mongosh --port 27017 --quiet <<EOF
rs.initiate({
  _id: "config_rs",
  configsvr: true,
  members: [{ _id: 0, host: "configsvr:27017" }]
})
EOF

echo "2. Инициализация replica set шарда 1 (3 узла)"
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

echo "3. Инициализация replica set шарда 2 (3 узла)"
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

echo "Ожидание выбора primary в реплика сетах (20 сек)..."
sleep 20

echo "4. Добавление шардов в кластер через mongos"
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<EOF
sh.addShard("shard1_rs/shard1_node1:27018,shard1_node2:27018,shard1_node3:27018")
sh.addShard("shard2_rs/shard2_node1:27019,shard2_node2:27019,shard2_node3:27019")
EOF

echo "5. Включение шардирования для базы и коллекции"
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<EOF
sh.enableSharding("somedb")
sh.shardCollection("somedb.helloDoc", { "_id": "hashed" })
EOF

echo "6. Наполнение базы тестовыми данными"
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<EOF
use somedb
var bulk = db.helloDoc.initializeUnorderedBulkOp()
for (var i = 0; i < 1000; i++) {
  bulk.insert({ name: "user_" + i, age: Math.floor(Math.random() * 60) + 18 })
}
bulk.execute()
EOF

echo "Готово. Приложение доступно на http://localhost:8080"
