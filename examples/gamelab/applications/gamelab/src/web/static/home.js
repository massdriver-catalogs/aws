// Labs take minutes to build or remove; check again until nothing is moving.
if (document.querySelector(".state-building, .state-removing")) {
  setTimeout(() => location.reload(), 15000);
}
