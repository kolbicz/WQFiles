// The top-level keys of a JSON file. Objects and arrays are shown as JSON.
function inspect(input, data) {
  if (input.text === null) throw new Error("This file is not UTF-8 text.");
  const value = JSON.parse(input.text);
  const isObject = value !== null && typeof value === "object" && !Array.isArray(value);
  const rows = isObject
    ? Object.keys(value).map(key => ({ label: key, value: value[key] }))
    : [{ label: "Value", value: value }];
  return {
    title: input.name,
    sections: [
      { title: "File", rows: [
        { label: "Size", value: input.size + " bytes" },
        { label: "Top-level type", value: Array.isArray(value) ? "array" : typeof value }
      ] },
      { title: "Top level", rows: rows }
    ]
  };
}
