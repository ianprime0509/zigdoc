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

const std = await execute({
  method: "addModule",
  params: { rootPath: "std.zig", sourceTarGz },
});

const declTitle = document.getElementById("decl-title");
const declDoc = document.getElementById("decl-doc");
const declNamespacesSection = document.getElementById(
  "decl-namespaces-section",
);
const declNamespaces = document.getElementById("decl-namespaces");
const declTypesSection = document.getElementById("decl-types-section");
const declTypes = document.getElementById("decl-types");
const declFunctionsSection = document.getElementById("decl-functions-section");
const declFunctions = document.getElementById("decl-functions");
const declValuesSection = document.getElementById("decl-values-section");
const declValues = document.getElementById("decl-values");

if (window.location.hash === "") {
  window.location.hash = "#doc/std";
}

await navigateTo(window.location.hash.slice(1));

async function navigateTo(loc) {
  if (loc.startsWith("doc/")) {
    const path = loc.slice("doc/".length);
    declTitle.innerText = path;
    // TODO
    const file = await execute({ method: "rootFile", params: { mod: std } });
    const decl = await execute({
      method: "rootDecl",
      params: { mod: std, file },
    });
    const children = await execute({
      method: "declChildren",
      params: { mod: std, decl },
    });

    declNamespaces.innerHTML = "";
    declTypes.innerHTML = "";
    declFunctions.innerHTML = "";
    declValues.innerHTML = "";
    for (const child of children) {
      const childItem = document.createElement("li");
      const childTitle = document.createElement("label");
      childTitle.innerText = child.name;
      childTitle.style = "font-weight: bold; margin-right: 1rem";
      childItem.appendChild(childTitle);
      const childDoc = document.createElement("span");
      childDoc.innerHTML = child.doc;
      childItem.appendChild(childDoc);

      switch (child.type) {
        case "namespace":
          declNamespaces.appendChild(childItem);
          break;
        case "type":
          declTypes.appendChild(childItem);
          break;
        case "function":
          declFunctions.appendChild(childItem);
          break;
        case "value":
          declValues.appendChild(childItem);
          break;
      }
    }
  }
}

const file = await execute({ method: "rootFile", params: { mod: std } });

console.log(
  await execute({ method: "fileSource", params: { mod: std, file } }),
);

const decl = await execute({ method: "rootDecl", params: { mod: std, file } });

console.log(
  await execute({ method: "declChildren", params: { mod: std, decl } }),
);

const mem = await execute({
  method: "declChild",
  params: { mod: std, decl, name: "mem" },
});

console.log(mem);

console.log(
  await execute({ method: "declChildren", params: { mod: std, decl: mem } }),
);

// For debugging purposes, it is useful to have the execute function available
// for use from the browser console.
window.zigdocExecute = execute;
