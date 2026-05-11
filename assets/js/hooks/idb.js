// Tiny IndexedDB wrapper for the recorder queue.
// One DB per origin; one object store keyed by chunkId composite.
// Schema is intentionally narrow — Phase 0 only.

const DB_NAME = "interview_recorder";
const DB_VERSION = 1;
const STORE = "chunks";

function open() {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, DB_VERSION);
    req.onupgradeneeded = (event) => {
      const db = req.result;
      if (!db.objectStoreNames.contains(STORE)) {
        const store = db.createObjectStore(STORE, { keyPath: "id" });
        // Composite (sessionId, questionIndex, attemptNumber, captureInstanceId, chunkIndex) → "id".
        store.createIndex("attempt", ["sessionId", "questionIndex", "attemptNumber"], { unique: false });
        store.createIndex("instance", ["sessionId", "questionIndex", "attemptNumber", "captureInstanceId"], { unique: false });
      }
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

function tx(db, mode, fn) {
  return new Promise((resolve, reject) => {
    const transaction = db.transaction(STORE, mode);
    const store = transaction.objectStore(STORE);
    let result;
    try {
      result = fn(store);
    } catch (err) {
      reject(err);
      return;
    }
    transaction.oncomplete = () => resolve(result);
    transaction.onerror = () => reject(transaction.error);
    transaction.onabort = () => reject(transaction.error || new Error("aborted"));
  });
}

function rowId({ sessionId, questionIndex, attemptNumber, captureInstanceId, chunkIndex }) {
  return [sessionId, questionIndex, attemptNumber, captureInstanceId, chunkIndex].join("|");
}

export async function putChunk(row) {
  const db = await open();
  return tx(db, "readwrite", (store) => store.put({ id: rowId(row), ...row }));
}

export async function deleteChunk(key) {
  const db = await open();
  return tx(db, "readwrite", (store) => store.delete(rowId(key)));
}

export async function listForInstance({ sessionId, questionIndex, attemptNumber, captureInstanceId }) {
  const db = await open();
  return new Promise((resolve, reject) => {
    const transaction = db.transaction(STORE, "readonly");
    const store = transaction.objectStore(STORE);
    const index = store.index("instance");
    const range = IDBKeyRange.only([sessionId, questionIndex, attemptNumber, captureInstanceId]);
    const req = index.getAll(range);
    req.onsuccess = () => {
      const rows = req.result || [];
      rows.sort((a, b) => a.chunkIndex - b.chunkIndex);
      resolve(rows);
    };
    req.onerror = () => reject(req.error);
  });
}

export async function totalBufferedBytes() {
  const db = await open();
  return new Promise((resolve, reject) => {
    const transaction = db.transaction(STORE, "readonly");
    const store = transaction.objectStore(STORE);
    const req = store.openCursor();
    let bytes = 0;
    req.onsuccess = () => {
      const cursor = req.result;
      if (!cursor) return resolve(bytes);
      const blob = cursor.value && cursor.value.blob;
      if (blob && typeof blob.size === "number") bytes += blob.size;
      cursor.continue();
    };
    req.onerror = () => reject(req.error);
  });
}
