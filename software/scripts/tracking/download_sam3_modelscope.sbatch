#!/usr/bin/env bash
#SBATCH --job-name=dl-sam3
#SBATCH --partition=GPU
#SBATCH --nodelist=4090node1
#SBATCH --cpus-per-task=2
#SBATCH --time=02:00:00
#SBATCH --output=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment/logs/download-sam3-%j.out
#SBATCH --error=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment/logs/download-sam3-%j.err

set -euo pipefail
ROOT=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment
DEST="$ROOT/models/sam3-modelscope"
BASE=https://www.modelscope.cn/models/facebook/sam3/resolve/master
STATUS="$ROOT/status/sam3_modelscope_download.status"
mkdir -p "$DEST" "$ROOT/logs" "$ROOT/status"
printf 'RUNNING job=%s time=%s\n' "$SLURM_JOB_ID" "$(date -Is)" > "$STATUS"
trap 'rc=$?; printf "FAILED job=%s rc=%s time=%s\n" "$SLURM_JOB_ID" "$rc" "$(date -Is)" > "$STATUS"; exit "$rc"' ERR

download() {
  local name=$1
  curl --fail --location --retry 8 --retry-all-errors --continue-at - \
    "$BASE/$name" --output "$DEST/$name"
}

for name in sam3.pt config.json configuration.json processor_config.json \
  tokenizer.json tokenizer_config.json special_tokens_map.json merges.txt \
  vocab.json LICENSE README.md; do
  download "$name"
done

cat > "$DEST/SHA256SUMS.expected" <<'EOF'
9999e2341ceef5e136daa386eecb55cb414446a00ac2b55eb2dfd2f7c3cf8c9e  sam3.pt
4616385e4b21f2e5e22c875b65679185cbccfa95de42542b9166f7dc3d57160f  config.json
1d6fb798aa860e22bb963db70c1d08b7f81512d62b89ce59d78e463633fcb531  configuration.json
6420cf2671fa9309ea95bc0144a8b9861666d1c5f43c8db09e410dacda974fce  processor_config.json
6d9109cc838977f3ca94a379eec36aecc7c807e1785cd729660ca2fc0171fb35  tokenizer.json
39670ad98457fe8f14ca59f6bb74591e9fc850974380a63993e5b8ffc865baa2  tokenizer_config.json
2cdb3b8331a60c92fc1e55a13e9fd61fd2293c5a51275fdcccd62b780052530e  special_tokens_map.json
9fd691f7c8039210e0fced15865466c65820d09b63988b0174bfe25de299051a  merges.txt
5047b556ce86ccaf6aa22b3ffccfc52d391ea4accdab9c2f2407da5b742d4363  vocab.json
bec48f70bd37bf8280a9d1ebf01642d26086f6122ba735baa08fe03c5a6e7448  LICENSE
1ac8a322aa4a797db79cbc334acee7c0cae8635032b71c7d5b23ae63a05f4bd5  README.md
EOF

(cd "$DEST" && sha256sum --check SHA256SUMS.expected)
du -sh "$DEST"
printf 'COMPLETE job=%s path=%s time=%s\n' "$SLURM_JOB_ID" "$DEST" "$(date -Is)" > "$STATUS"
