const age = document.getElementById("age");
const lesson = document.getElementById("lesson");
const chips = document.querySelectorAll(".chip");

function showIdeas() {
  const a = Number(age.value);
  for (const chip of chips) {
    chip.hidden = a < Number(chip.dataset.min) || a > Number(chip.dataset.max);
  }
}

for (const chip of chips) {
  chip.addEventListener("click", () => {
    lesson.value = chip.dataset.lesson;
    lesson.focus();
  });
}
age.addEventListener("change", showIdeas);
showIdeas();
