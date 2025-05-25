**Power_Node Feature List**

**1. Core Blockchain Functionality**
    *   **Block Management:**
        *   Creation of new blocks, likely orchestrated by `mkblock.erl`.
        *   Validation of block contents and signatures.
        *   Storage of blocks, likely using RocksDB via `mledger.erl` or directly.
        *   Retrieval of blocks by hash or height (`blockchain_reader.erl`).
        *   Updating the blockchain state upon acceptance of new blocks (`blockchain_updater.erl`).
        *   The `block.erl` module likely defines the block structure.
    *   **Genesis Block:**
        *   Handling of the initial block that starts a chain (`genesis.erl`, `genesis_easy.erl`).
    *   **Chain Settings (`chainsettings.erl`):**
        *   Management and retrieval of chain-specific parameters (e.g., consensus rules, fee structures, node lists).
    *   **Blockchain Synchronization:**
        *   Mechanisms to synchronize the local blockchain state with other nodes in the network (`blockchain_sync.erl`, `synchronizer.erl`).
        *   Ledger synchronization specific to account states and other ledger data (`ledger_sync.erl`).
    *   **Consensus (Implied):**
        *   `blockvote.erl` suggests a system where nodes vote on the validity or inclusion of blocks.
        *   `chainkeeper.erl` likely implements logic for maintaining the integrity and correctness of the main chain, possibly handling forks.
    *   **Merkle Roots:**
        *   Calculation and storage of Merkle roots for transactions and receipts within block headers (implied by standard blockchain architecture and presence of `gb_merkle_trees`, `db_merkle_trees` dependencies).

**2. Networking**
    *   **Custom P2P Protocol (tpic2 - `apps/tpic2`):**
        *   Core modules: `tpic2.erl` (main application logic), `tpic2_cmgr.erl` (connection manager), `tpic2_client.erl`, `tpic2_peer.erl`, `tpic2_tls.erl`.
        *   Manages direct peer-to-peer connections between nodes.
        *   Supports message casting (broadcast/unicast) and RPC-like calls between peers for inter-node communication.
        *   Uses `nodekey.erl` for node identity and `tpecdsa.erl` for cryptographic operations within the P2P layer.
        *   Generates and manages SSL certificates for secure P2P communication, potentially integrated with Yggdrasil network naming.
    *   **Yggdrasil Integration (`apps/yggerl`):**
        *   The `yggerl` application and `yggstack.erl` (with `ygg.erl`) suggest integration with the Yggdrasil Network for an alternative or complementary networking layer, possibly for enhanced routing or mesh networking.
        *   `tpnode_sup.erl` can start `yggstack`.
        *   `tpic2.erl`'s `yggname/1` function implies use of Yggdrasil's naming scheme.
    *   **Peer Discovery (`discovery.erl`):**
        *   Mechanism for nodes to find and connect to other peers in the network.
        *   Likely uses a combination of seed nodes and dynamic discovery.
    *   **Interconnect (`interconnect.erl`):**
        *   May manage data exchange or connections between different internal components of the node or across different network layers/services.
    *   **Node Announcer (`tpnode_announcer.erl`):**
        *   Responsible for announcing the node's presence, capabilities, or services to the network.
    *   **Topology Management (`topology.erl`):**
        *   Likely involved in understanding and maintaining a map or state of the network's structure and connectivity.

**3. API Endpoints**
    *   **JSON-RPC API (`cowboy_jsonrpc.erl`, `tpnode_jsonrpc.erl`):**
        *   Implemented using the Cowboy web server.
        *   Provides endpoints over HTTP and WebSockets.
        *   Supports a wide array of Ethereum-compatible JSON-RPC methods for interacting with the blockchain, sending transactions, querying data, etc. (e.g., `eth_sendRawTransaction`, `eth_getBlockByNumber`, `eth_call`, `eth_getLogs`, `net_version`).
    *   **General HTTP API (`tpnode_http.erl`, `tpnode_httpapi.erl`, `apixiom.erl`):**
        *   Provides RESTful HTTP endpoints for a broader range of functionalities beyond Ethereum RPC compatibility.
        *   Endpoints include:
            *   Node status and information (`/node/status`).
            *   Node backup and restore (`/node/backup`, `/node/backup.zip`).
            *   Node control operations like rollback and sync (`/node/rollback`, `/node/runsync`).
            *   Peer management (`/node/new_peer`).
            *   Applying hotfixes (`/node/hotfix`).
            *   Address and ledger queries (detailed state, code, sequence numbers, `lstore` data: `/address/...`).
            *   Block retrieval and information (`/blockinfo/...`, `/blockn/...`, `/block/...`).
            *   Raw block data access (`/binblockn/...`, `/binblock/...`, `/txtblock/...`).
            *   Access to node and chain settings (`/settings/...`).
            *   Transaction submission and simulation (`/tx/new`, `/tx/batch`, `/tx/simulate`).
            *   Transaction status queries (`/tx/status/...`).
            *   Retrieval of event logs (`/logs/...`).
            *   API playground for easier interaction (`/playground/...`).
    *   **WebSocket API (`ws_dispatcher.erl`, `tpnode_ws.erl`):**
        *   Used for real-time communication, pushing updates, and event subscriptions from the node to clients.
    *   **Cross-Chain API (`xchain_server.erl`, `xchain_api.erl`):**
        *   Dedicated API endpoints for initiating or managing cross-chain interactions.
    *   **TPIC2 API (`tpnode_tpicapi.erl`):**
        *   Specific API for interacting with the `tpic2` P2P layer, possibly for diagnostics or direct peer manipulation.
    *   **SSL/TLS Support:**
        *   APIs can be served over HTTPS. `tpnode_http.erl` includes logic for SSL certificate handling, including on-the-fly generation of self-signed certificates if necessary.

**4. Smart Contract Capabilities**
    *   **Ethereum Virtual Machine (EVM) (`contract_evm.erl`):**
        *   Depends on `eevm` and `eevm_abi` libraries.
        *   Deployment of EVM bytecode to create new smart contracts.
        *   Execution of calls to existing EVM smart contracts.
        *   Manages contract state (storage), code, and balances within the EVM context.
        *   Gas mechanism for metering computation during EVM execution.
        *   Support for Solidity smart contract interactions via ABI encoding/decoding for function calls and event data.
        *   **Embedded Functions:** Special pre-compiled functions accessible from within the EVM via designated addresses, allowing contracts to query node internals (e.g., settings, block information, `lstore` data, trigger key changes, use Bron-Kerbosch algorithm).
        *   **ERC165 Interface Detection:** `ask_ERC165/3` suggests support for checking if a contract implements specific interfaces.
        *   **Transaction Sponsorship:** `ask_if_sponsor/1` and `ask_if_wants_to_pay/4` imply a mechanism where contracts (sponsors) can pay for other users' transactions.
    *   **WebAssembly (Wasm) (Placeholder) (`contract_wasm.erl`):**
        *   Indicates an intention to support WebAssembly (Wasm) as another smart contract engine.
        *   Depends on the `wanode` library.
        *   The `tpnode_sup.erl` starts a `wasm_vm` process.
        *   Current implementation in `contract_wasm.erl` appears to be a placeholder and throws `wasm_vm_broken`, suggesting it's not fully functional yet.

**5. Transaction Types and Handling**
    *   **Core Transaction Logic (`tx.erl`):**
        *   Handles transaction creation, serialization (packing/unpacking to/from binary formats using `msgpack`), digital signing, and signature verification.
        *   Supports multiple transaction versions (at least version 1 and version 2 are mentioned).
    *   **Transaction Kinds (Version 2):**
        *   `patch`: System-level transaction to update settings or parameters.
        *   `register`: Likely for registering new addresses or associating metadata with them.
        *   `tstore`: Operations related to a token store, possibly for fungible token transfers.
        *   `lstore`: Operations related to a general ledger store, allowing for arbitrary data to be stored on-chain associated with an address.
        *   `deploy`: For deploying new smart contracts (both EVM and potentially Wasm).
        *   `notify`: For emitting events or sending notifications that can be indexed and queried.
        *   `chkey`: For changing the cryptographic keys associated with an address.
        *   `generic`: A general-purpose transaction type, often used for calling smart contract functions.
        *   `ether`: Ethereum-compatible transaction type, specifically for interacting with the EVM.
    *   **Signing and Verification:**
        *   Uses Ed25519 digital signatures via `bsig.erl` (likely a wrapper) and `tpecdsa.erl`.
        *   Supports multiple signatures for transactions that might require them.
    *   **Transaction Pool (`txpool.erl`):**
        *   Manages a pool of pending transactions received from the network or APIs.
        *   Verifies incoming transactions (`tx:verify/1`).
        *   Generates unique transaction identifiers (`generate_txid/1`).
        *   Forwards transactions to `txstorage` for persistence.
        *   If the node is configured as a replica, it forwards new transactions to an upstream node.
    *   **Transaction Queue (`txqueue.erl`):**
        *   Orders transactions, likely based on fees, sequence numbers, or arrival time, before they are included in a block.
        *   Interfaces with the block creation process (`mkblock.erl`) to provide batches of transactions.
        *   Manages the lifecycle of transactions through the processing pipeline.
    *   **Transaction Storage (`txstorage.erl` - existence implied):**
        *   Persistent storage for transactions, allowing retrieval by ID. `txpool.erl` interacts with it.
    *   **Transaction Status Tracking (`txstatus.erl`):**
        *   Tracks the status of transactions (e.g., pending, included in block, failed).
    *   **Transaction Structure:**
        *   Common fields include `from`, `to`, `t` (timestamp), `seq` (sequence number).
        *   `payload`: Can contain a list of operations, each specifying an amount, currency, and purpose (e.g., `transfer`, `srcfee`, `gas`).
        *   `call`: For smart contract interactions, specifying the function and arguments.
        *   `txext`: A map for extended or custom transaction data.
        *   `patches`: Used in `patch` and `lstore` transactions for specifying changes.
    *   **Fee Calculation (`tx:rate/2`):**
        *   A mechanism to determine the cost (fee) of a transaction based on its size, operations, or other factors.

**6. Ledger and State Management**
    *   **Underlying Storage (RocksDB):**
        *   The `rocksdb` Erlang binding is a key dependency, indicating its use as the primary key-value store for persistent data.
        *   `rdb_dispatcher.erl` likely manages access to RocksDB instances.
    *   **Ledger Abstraction (`mledger.erl`):**
        *   Provides a higher-level API for interacting with the blockchain's ledger.
        *   Stores and retrieves account-related information:
            *   Balances for different currencies/tokens.
            *   Sequence numbers for transaction ordering from an account.
            *   Public keys associated with addresses.
            *   Smart contract code.
            *   Smart contract state (storage).
        *   Implements the `lstore` functionality for arbitrary key-value data storage linked to addresses.
    *   **Address Management (`address.erl`, `address_db.erl`, `naddress.erl`):**
        *   Handles different types of addresses (e.g., Power addresses, Ethereum-style addresses).
        *   Provides encoding and decoding functions for these address formats.
    *   **Log Storage (`logs_db.erl`):**
        *   A dedicated database or table structure for storing event logs emitted by smart contracts, queryable via APIs.
    *   **State Merkleization (Implied):**
        *   The ledger's state is likely organized in a Merkle tree structure (or similar) to generate a concise state root that can be included in block headers, ensuring data integrity and enabling light client proofs. Dependencies like `gb_merkle_trees` and `db_merkle_trees` support this.

**7. Cross-Chain Features**
    *   **Dedicated Modules:** The presence of `xchain_client.erl`, `xchain_dispatcher.erl`, `xchain_api.erl`, and `xchain_server.erl` strongly indicates built-in capabilities for interacting with other blockchains or facilitating cross-chain operations.
    *   **Functionality:** The specifics (e.g., asset transfers, data exchange, atomic swaps) would require deeper analysis of these modules but suggest a significant feature set.

**8. Node Management & Utilities**
    *   **Configuration:**
        *   Primary configuration loaded from `node.config` (as shown in `tpnode.erl`).
        *   `sys.config` for core Erlang system parameters.
        *   `erun.config` for the `erun` application.
        *   Support for overriding configurations via environment variables.
    *   **Application Supervision (`tpnode_sup.erl`):**
        *   The heart of the node, managing the lifecycle (start, stop, restart) of all critical worker processes using OTP supervisor principles.
    *   **Node Identity (`nodekey.erl`):**
        *   Manages the node's unique cryptographic identity (private and public key pair).
    *   **Backup and Restore:**
        *   `tpnode_backup.erl` provides functionality to create backups of node data.
        *   `tpnode_sup.erl` includes `try_restore_db/1` to attempt restoring from a backup on startup.
    *   **Hotfixes (`tpnode_hotfix.erl`):**
        *   A system for applying live code patches or updates to a running node without full restart.
    *   **Logging Framework (`tplog.hrl`):**
        *   A custom logging framework providing macros (`?LOG_INFO`, `?LOG_ERROR`, etc.).
        *   Supports different log levels.
        *   Configurable logging per module or topic (e.g., `consensus_log`, `mkblock_log`, `chain_log` in `tpnode.erl`).
        *   File-based logging with rotation.
    *   **Watchdog (`tpwdt.erl`, `tpwdt_worker.erl`):**
        *   A watchdog process to monitor the health and responsiveness of the node, potentially triggering recovery actions.
    *   **Debugging Utilities (`debug_tools.erl`):**
        *   A collection of utility functions to aid in debugging the node.
    *   **Encoding/Decoding Utilities:**
        *   `hex.erl`: For hexadecimal encoding/decoding.
        *   `base58.erl`: For Base58 encoding/decoding.
        *   `bin2hex.erl`: Another binary to hex utility.
    *   **`erun` Application (`apps/erun`):**
        *   A simple utility application, possibly for running small scripts or managing simple processes alongside the main node.
    *   **Build & CI Scripts (`bin/`):** Shell scripts for building releases and running CI checks.
