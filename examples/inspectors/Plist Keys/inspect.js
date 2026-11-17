// The keys of a binary or XML property list. data.json maps known keys to
// readable names; input.plist is the parsed file (dates as ISO 8601, data
// as base64), or null when the file isn't a property list.
function inspect(input, data) {
  const plist = input.plist;
  if (plist === null) throw new Error("This file is not a property list.");
  if (typeof plist !== "object" || Array.isArray(plist))
    return { sections: [{ title: "Value", text: JSON.stringify(plist, null, 2) }] };
  const known = [], other = [];
  for (const key of Object.keys(plist).sort()) {
    const name = data.names[key];
    (name ? known : other).push({ label: name ? name + " (" + key + ")" : key, value: plist[key] });
  }
  console.log(Object.keys(plist).length + " keys");
  return {
    title: input.name,
    sections: [
      { title: "Known keys", rows: known.length ? known : [{ label: "", value: "none" }] },
      { title: "Other keys", rows: other }
    ]
  };
}
