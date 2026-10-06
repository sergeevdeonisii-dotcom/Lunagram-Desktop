#include "pch.h"
#include "after.h"

int main() {
	const auto values = std::vector<int>{ PROBE_VALUE };
	std::cout << values.front() + PROBE_ADJUSTMENT;
	return 0;
}
