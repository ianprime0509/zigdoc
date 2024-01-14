const execute = await (async () => {
  const worker = new Worker("worker.js", { type: "module" });

  const promises = {};

  const init = new Promise((resolve, reject) => {
    promises[0] = { resolve, reject };
  });

  worker.onerror = (e) => console.error("Worker error", e);

  worker.onmessage = ({ data }) => {
    const promise = promises[data.id];
    delete promises[data.id];

    if ("error" in data) {
      promise.reject(data.error);
    } else {
      promise.resolve(data.result);
    }
  };

  let nextId = await init;

  return (message) =>
    new Promise((resolve, reject) => {
      const id = nextId++;
      promises[id] = { resolve, reject };
      worker.postMessage({ id, ...message });
    });
})();

const sourceTarGz = new Uint8Array(
  await (await fetch("std.tar.gz")).arrayBuffer(),
);

const mod = await execute({
  method: "addModule",
  params: { rootPath: "std.zig", sourceTarGz },
});
console.log(mod);

console.log(await execute({ method: "fileSource", params: { mod, file: 0 } }));
