-- init_db.sql
CREATE TABLE IF NOT EXISTS transaction (
    transaction_id VARCHAR(50) PRIMARY KEY UNIQUE NOT NULL,
    amount FLOAT NOT NULL,
    timestamp TIMESTAMP NOT NULL
);