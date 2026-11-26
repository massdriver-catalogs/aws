<?php
$app = getenv('APP_NAME') ?: 'php';
$name = htmlspecialchars($app);
?>
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title><?= $name ?> · Tendwell Supply</title>
  <style>
    body { font-family: system-ui, sans-serif; margin: 4rem auto; max-width: 36rem; padding: 0 1rem; color: #1d2433; }
    p { color: #5b6475; }
  </style>
</head>
<body>
  <h1><?= $name ?></h1>
  <p>Tendwell Supply · PHP <?= PHP_VERSION ?> · <?= htmlspecialchars(gethostname()) ?></p>
</body>
</html>
