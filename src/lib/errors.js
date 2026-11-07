export const fail = (message, status = 400) => {
  const error = new Error(message);
  error.status = status;
  error.expose = true;
  throw error;
};
export const check = ({ data, error }) => {
  if (error) {
    if (error.code === 'P0001') fail('This operation is not permitted in the current state.', 409);
    if (error.code === '23505')
      fail('This record already exists. Check the name or try refreshing.');
    if (error.code === '42501') fail('You do not have permission for this action.', 403);
    if (error.code === 'PGRST202' || error.code === '42P01' || error.code === '42703')
      fail('Run the latest GameOn SQL migrations in Supabase first.', 503);
    fail('Database operation failed. Check your setup and try again.');
  }
  return data;
};
