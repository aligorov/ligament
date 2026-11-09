#!/usr/bin/env bash
set -e

# Создание пользователей и баз данных для Chat и Ticket
# База данных ligament_recorder и пользователь recorder создаются автоматически Postgres-образом
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE USER chat;
    CREATE DATABASE ligament_chat OWNER chat;
    GRANT ALL PRIVILEGES ON DATABASE ligament_chat TO chat;

    CREATE USER ticket;
    CREATE DATABASE ligament_ticket OWNER ticket;
    GRANT ALL PRIVILEGES ON DATABASE ligament_ticket TO ticket;
EOSQL
