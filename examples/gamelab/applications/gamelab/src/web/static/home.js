// Labs take minutes to build or remove, and about one to wake; check again
// until nothing is moving.
if (document.querySelector(".state-waking")) {
  setTimeout(() => location.reload(), 4000);
} else if (document.querySelector(".state-building, .state-removing")) {
  setTimeout(() => location.reload(), 15000);
}
