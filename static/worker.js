const wasm = (await WebAssembly.instantiateStreaming(fetch("zigdoc.wasm"), {}))
  .instance.exports;

function handle(ret) {
  if (ret < 0) {
    // TODO: function to stringify error codes
    throw new Error(`Error ${-ret - 1}`);
  }
  return ret;
}

const clientMemory = (() => {
  let addr;
  let len = 0;

  class OutValue {
    constructor(len) {
      this.len = len;
    }
  }

  return {
    OutValue,

    ensureTotalCapacity(newLen) {
      if (newLen > len) {
        addr = handle(wasm.ensureTotalClientMemoryCapacity(newLen)) * 2;
        len = newLen;
      }
    },

    encode(...values) {
      const neededLen = values
        .map((value) => {
          if (typeof value === "string") {
            // A UTF-16 code unit cannot represent more than 3 bytes of UTF-8.
            // TODO: this is overly pessimistic
            return value.length * 3;
          } else if (value instanceof Uint8Array) {
            return value.length;
          } else if (value instanceof OutValue) {
            return value.len;
          }
        })
        .reduce((v1, v2) => v1 + v2, 0);
      this.ensureTotalCapacity(neededLen);

      const encoded = [];
      let pos = addr;
      for (const value of values) {
        if (typeof value === "string") {
          const { written } = new TextEncoder().encodeInto(
            value,
            new Uint8Array(wasm.memory.buffer, pos),
          );
          encoded.push(pos, written);
          pos += written;
        } else if (value instanceof Uint8Array) {
          new Uint8Array(wasm.memory.buffer, pos).set(value);
          encoded.push(pos, value.length);
          pos += value.length;
        } else if (value instanceof OutValue) {
          value.addr = pos;
          encoded.push(pos);
          pos += value.len;
        }
      }
      return encoded;
    },

    get addr() {
      return addr;
    },

    get len() {
      return len;
    },

    readU32(ptr) {
      if (ptr instanceof OutValue) ptr = ptr.addr;
      return new Uint32Array(wasm.memory.buffer, ptr, 4)[0];
    },

    readString(ptr, len) {
      return new TextDecoder().decode(
        new Uint8Array(wasm.memory.buffer, ptr, len),
      );
    },
  };
})();

const methods = {
  addModule({ rootPath, sourceTarGz }) {
    return handle(
      wasm.addModule(...clientMemory.encode(rootPath, sourceTarGz)),
    );
  },

  rootFile({ mod }) {
    return handle(wasm.rootFile(mod));
  },

  rootDecl({ mod, file }) {
    return handle(wasm.rootDecl(mod, file));
  },

  fileSource({ mod, file }) {
    const sourcePtr = new clientMemory.OutValue(4);
    const sourceLen = new clientMemory.OutValue(4);
    handle(
      wasm.fileSource(mod, file, ...clientMemory.encode(sourcePtr, sourceLen)),
    );
    return clientMemory.readString(
      clientMemory.readU32(sourcePtr),
      clientMemory.readU32(sourceLen),
    );
  },

  declChildren({ mod, decl }) {
    const jsonPtr = new clientMemory.OutValue(4);
    const jsonLen = new clientMemory.OutValue(4);
    handle(
      wasm.declChildren(mod, decl, ...clientMemory.encode(jsonPtr, jsonLen)),
    );
    return JSON.parse(
      clientMemory.readString(
        clientMemory.readU32(jsonPtr),
        clientMemory.readU32(jsonLen),
      ),
    );
  },

  declChild({ mod, decl, name }) {
    const index = handle(
      wasm.declChild(mod, decl, ...clientMemory.encode(name)),
    );
    return index === 0x7fff_ffff ? null : index;
  },
};

onmessage = ({ data: { id, method, params } }) => {
  try {
    const result = methods[method](params);
    postMessage({ id, result });
  } catch (e) {
    console.error(`Error handling message ${id} (${method})`, e);
    postMessage({ id, error: e.message });
  }
};

postMessage({ id: 0, result: 1 });
