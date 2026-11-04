#!/bin/bash
# Crea en TU cuenta de pruebas los topics SNS de Nubeduca que necesitas para consumir
# eventos de otros roles antes de que ellos desplieguen. Es idempotente (se puede ejecutar varias veces).
# ⚠️ NO usar en la cuenta del despliegue final: ahí los crea el serverless.yml de cada productor.
#
# Uso:  ./crear_topics_dev.sh [stage]      (por defecto: dev)
#       ./crear_topics_dev.sh dev entrega-enviada      (solo un topic)

STAGE=${1:-dev}
shift
EVENTOS=${@:-"usuario-registrado estudiante-inscrito material-publicado entrega-enviada nota-publicada"}

for EVENTO in $EVENTOS; do
  ARN=$(aws sns create-topic --name "nubeduca-${STAGE}-${EVENTO}" --query TopicArn --output text)
  echo "OK  $ARN"
done
