# Use the official Python image
FROM python:3.9-slim

# Set the working directory
WORKDIR /app

# Copy the requirements file into the container
COPY requirements.txt requirements.txt

# Install dependencies for psycopg2.
RUN apt-get update \
    && apt-get -y install libpq-dev gcc \
    && pip install psycopg2

# Install the dependencies.
RUN pip install --no-cache-dir -r requirements.txt

# Copy the rest of the application code
COPY . .

# Expose the port the app runs on
EXPOSE 5000

# Run the application
RUN export OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED=true
CMD ["opentelemetry-instrument","python", "app.py"]