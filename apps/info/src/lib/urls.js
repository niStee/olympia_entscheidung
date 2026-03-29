const PROD_DEFAULT_QUIZ_URL = "https://olympiadusseldorf.de";

export const QUIZ_URL = import.meta.env.VITE_QUIZ_URL
  ? import.meta.env.VITE_QUIZ_URL
  : import.meta.env.PROD
    ? PROD_DEFAULT_QUIZ_URL
    : "http://localhost:3000";
