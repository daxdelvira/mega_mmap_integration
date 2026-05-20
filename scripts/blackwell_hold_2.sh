#!/bin/bash
#SBATCH -A gts-ag117
#SBATCH -J blackwell_hold_2
#SBATCH -p gpu-rtxpro-blackwell
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=12
#SBATCH --gres=gpu:4
#SBATCH -t 07:59:00
#SBATCH -q embers
#SBATCH --mail-type=BEGIN,FAIL
#SBATCH --mail-user=dax@gatech.edu

#SBATCH -o /storage/home/hcoda1/7/avandevoorde3/scratch/blackwell_hold_2/%j.out
#SBATCH -e /storage/home/hcoda1/7/avandevoorde3/scratch/blackwell_hold_2/%j.err

set -euo pipefail

BASE_DIR=/storage/home/hcoda1/7/avandevoorde3
LOG_DIR=/storage/home/hcoda1/7/avandevoorde3/scratch/blackwell_hold_2

mkdir -p "$LOG_DIR"

echo "JOB_ID=$SLURM_JOB_ID" | tee "$LOG_DIR/${SLURM_JOB_ID}.meta"
echo "HOSTNAME=$(hostname)" | tee -a "$LOG_DIR/${SLURM_JOB_ID}.meta"

echo "$(hostname)" > "$LOG_DIR/current_host.txt"

echo "Job started at $(date)"
echo "Running on node: $(hostname)"

nvidia-smi

touch /var/tmp/startup_complete

# Keep allocation alive
while true; do
    sleep 600
    echo "alive $(date)"
done
