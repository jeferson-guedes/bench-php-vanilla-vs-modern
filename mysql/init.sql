-- Executado automaticamente pelo container MySQL no primeiro boot
-- (montado em /docker-entrypoint-initdb.d/). Roda dentro do schema "benchmark".

CREATE TABLE IF NOT EXISTS logs_benchmark (
    id         INT AUTO_INCREMENT PRIMARY KEY,
    payload    TEXT NOT NULL,
    criado_em  DATETIME NOT NULL,
    INDEX idx_logs_benchmark_id (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Seed para o teste de leitura (/bench/io-read retorna os 20 mais recentes)
INSERT INTO logs_benchmark (payload, criado_em) VALUES
('seed-payload-0001', NOW()),
('seed-payload-0002', NOW()),
('seed-payload-0003', NOW()),
('seed-payload-0004', NOW()),
('seed-payload-0005', NOW()),
('seed-payload-0006', NOW()),
('seed-payload-0007', NOW()),
('seed-payload-0008', NOW()),
('seed-payload-0009', NOW()),
('seed-payload-0010', NOW()),
('seed-payload-0011', NOW()),
('seed-payload-0012', NOW()),
('seed-payload-0013', NOW()),
('seed-payload-0014', NOW()),
('seed-payload-0015', NOW()),
('seed-payload-0016', NOW()),
('seed-payload-0017', NOW()),
('seed-payload-0018', NOW()),
('seed-payload-0019', NOW()),
('seed-payload-0020', NOW()),
('seed-payload-0021', NOW()),
('seed-payload-0022', NOW()),
('seed-payload-0023', NOW()),
('seed-payload-0024', NOW()),
('seed-payload-0025', NOW()),
('seed-payload-0026', NOW()),
('seed-payload-0027', NOW()),
('seed-payload-0028', NOW()),
('seed-payload-0029', NOW()),
('seed-payload-0030', NOW());
