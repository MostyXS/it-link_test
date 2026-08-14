<?php

declare(strict_types=1);

header('Content-Type: application/json; charset=utf-8');

$dbName = getenv('POSTGRES_DB') ?: 'app_db';
$dbUser = getenv('POSTGRES_USER') ?: 'app_user';
$dbPass = getenv('POSTGRES_PASSWORD') ?: '';

$dsn = sprintf(
    'pgsql:host=postgres;port=5432;dbname=%s',
    $dbName
);

try {
    $pdo = new PDO(
        $dsn,
        $dbUser,
        $dbPass,
        [
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_TIMEOUT => 3,
        ]
    );

    $message = $pdo
        ->query('SELECT message FROM healthcheck WHERE id = 1')
        ->fetchColumn();

    http_response_code(200);

    echo json_encode(
        [
            'status' => 'ok',
            'database' => $dbName,
            'db_health' => $message,
        ],
        JSON_UNESCAPED_SLASHES
    );
} catch (Throwable $exception) {
    http_response_code(503);

    echo json_encode(
        [
            'status' => 'degraded',
            'database' => $dbName,
            'db_health' => 'unavailable',
        ],
        JSON_UNESCAPED_SLASHES
    );
}