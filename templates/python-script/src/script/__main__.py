import numpy as np
import matplotlib.pyplot as plt

import matplotlib
import seaborn as sns

matplotlib.use("qtagg")
sns.set_theme()


def main() -> None:
    x = np.linspace(0, 4 * np.pi, 200)
    y = np.sin(x)
    plt.plot(x, y)
    plt.show()


if __name__ == "__main__":
    main()
