# MySQL Manager

A Docker-based MySQL management tool that integrates with S3-compatible storage for database backups.

## Features

- MySQL database container
- Manager service with AWS CLI and MyCLI for database operations
- S3-compatible storage integration for backups
- Health checks and wait mechanisms for service dependencies

## Requirements

- Docker
- Docker Compose
- S3-compatible storage endpoint
- AWS credentials

## Configuration

1. Create an `aws.env` file with your AWS credentials:
   ```
   AWS_ACCESS_KEY_ID=your_access_key
   AWS_SECRET_ACCESS_KEY=your_secret_key
   ```

2. Place your certificate bundle as `cert.bundle.pem` for S3 endpoint verification.

3. Configure environment variables in `compose.yaml`:
   - `DB_HOST`: MySQL host (default: db)
   - `DB_PORT`: MySQL port (default: 3306)
   - `DB_USER`: MySQL username (default: root)
   - `DB_PASSWORD`: MySQL root password
   - `DB_NAME`: Database name
   - `DB_MANAGER`: Manager database name
   - `S3_BUCKET`: S3 bucket path for backups
   - `S3_ENDPOINT`: S3-compatible endpoint URL

## Usage

Start the services:
```bash
docker-compose up -d
```

View logs:
```bash
docker-compose logs -f
```

Stop the services:
```bash
docker-compose down
```

## Project Structure

- `compose.yaml`: Docker Compose configuration
- `Dockerfile`: Manager service image definition
- `run.sh`: Manager service entrypoint script
- `db.sql`: Database initialization SQL (to be implemented)
- `aws.env`: AWS credentials (not tracked in git)
- `cert.bundle.pem`: Certificate bundle for S3 endpoint

## Development

The manager service waits for:
1. MySQL database to be ready
2. S3 storage bucket to be accessible

Once both are available, the service is ready for database operations.
