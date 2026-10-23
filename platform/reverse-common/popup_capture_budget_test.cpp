#include "popup_capture_budget.hpp"
#include <cassert>
int main(){
    viewflow::reverse::PopupCaptureBudget budget;
    static_assert(viewflow::reverse::PopupCaptureBudget::frames_per_second == 30);
    budget.add(10);budget.add(20);
    assert(budget.begin(10,1));
    assert(!budget.begin(20,2)); // No second pair while the first is pending.
    budget.complete();
    assert(!budget.begin(20,1.01)); // Completion never bypasses the rate cap.
    assert(!budget.begin(10,1.034)); // Parent cannot starve the submenu.
    assert(budget.begin(20,1.034));
    budget.remove(20); // Closing a menu doesn't release its in-flight work.
    assert(!budget.begin(10,2));
    budget.complete();
    assert(budget.begin(10,2));
    budget.complete();budget.remove(10);
    assert(!budget.begin(10,3));
}
