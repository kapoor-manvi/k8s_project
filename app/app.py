from flask import Flask, request, jsonify
from flask_sqlalchemy import SQLAlchemy
from datetime import datetime
import uuid
import os

app = Flask(__name__)

# Database configuration
db_user = os.environ.get('POSTGRES_USER')
db_password = os.environ.get('POSTGRES_PASSWORD')
db_name = os.environ.get('POSTGRES_DB')
db_host = os.environ.get('POSTGRES_HOST')
app.config['SQLALCHEMY_ENGINE_OPTIONS'] = {"pool_pre_ping": True}
app.config['SQLALCHEMY_DATABASE_URI'] = f'postgresql://{db_user}:{db_password}@{db_host}/{db_name}'
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False

db = SQLAlchemy(app)

class Transaction(db.Model):
    transaction_id = db.Column(db.String(50), unique=True, primary_key=True, nullable=False, default=lambda: str(uuid.uuid4()))
    amount = db.Column(db.Float, nullable=False)
    timestamp = db.Column(db.DateTime, nullable=False)

    def __init__(self, transaction_id, amount, timestamp):
        self.transaction_id = transaction_id
        self.amount = amount
        self.timestamp = timestamp

@app.route('/api/transaction', methods=['POST'])
def insert_transaction():
    data = request.json
    transaction_id = data.get('transactionId')
    amount = data.get('amount')
    timestamp = data.get('timestamp')

    if not all([transaction_id, amount, timestamp]):
        return jsonify({"error": "Missing data"}), 400

    try:
        timestamp = datetime.fromisoformat(timestamp)
    except ValueError:
        return jsonify({"error": "Invalid timestamp format"}), 400

    new_transaction = Transaction(transaction_id, amount, timestamp)
    db.session.add(new_transaction)
    db.session.commit()

    return jsonify({"message": "Transaction added"}), 201

if __name__ == '__main__':
    app.run(host='0.0.0.0')
