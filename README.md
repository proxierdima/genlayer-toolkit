# GenLayer Toolkit

Minimal CLI toolkit for installing and running a GenLayer full node.

---

## Features

- Bootstrap GenLayer node + genvm
- Interactive configuration (RPC, WSS, consensus, LLM provider)
- Reuse existing config (no repeated prompts)
- Docker-based node management
- Simple terminal UI (gum)
- All logic in a single `toolkit.sh` (procedures, no external scripts)

---

## Installation

```bash
bash toolkit_install.sh genlayer-toolkit
cd ~/genlayer-toolkit
./toolkit.sh
```


## Menu Structure

### Main
- Install
- Stack
- Check configuration
- Exit

### Install
- Install full node
- Bootstrap workspace only
- Configure existing workspace

### Stack
- Start webdriver
- Start node
- Start full stack
- Stop full stack
- Restart node stack
- Follow node logs

---

## Install Flow

**Install → Install full node**

Sequence:
1. Bootstrap workspace  
2. Configure node  
3. Validate config  
4. Start webdriver  
5. Start node  

---

## Configuration

**Files:**
```bash
genlayer/
├── .env
└── configs/node/config.yaml
```

**Required:**
- HTTP RPC URL  
- WSS RPC URL  
- Consensus address (0x...)  
- Genesis block  
- LLM provider + API key  

---

## Commands

**Start node**
```bash
docker compose --profile node up -d
```

### Start full stack

```bash
docker compose --profile node --profile monitoring up -d
```

### Stop stack
```bash
docker compose --profile node --profile monitoring down
```
Restart node
```bash
docker compose --profile node restart
```
### Logs
```bash
docker compose --profile node logs -f
```

## Precheck

**Run:**

Check configuration

**Result:**

PRECHECK: OK

## Errors:

- missing RPC / WSS
- invalid consensus address
- missing LLM key

## Notes
- Webdriver must run before node
- Paths in .env are absolute
- Only full node mode supported
- Docker required

## Structure
- toolkit.sh — main CLI (all logic)
- examples/ — templates
- docs/ — minimal docs
