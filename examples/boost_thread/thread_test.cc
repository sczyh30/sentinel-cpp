#include <boost/thread.hpp>

#include <iostream>

void thread()
{
  std::cout << "Test" << std::endl;
}

int main()
{
  boost::thread t{thread};
  t.join();
  return 0;
}
